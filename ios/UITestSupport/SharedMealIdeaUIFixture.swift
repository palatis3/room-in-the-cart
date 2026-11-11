#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI
import HouseholdClient
import CoreDomain

private final class S26FixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
private final class S26FixtureServer: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let shopper = "22222222-2222-4222-8222-222222222222"
    static let planner = "33333333-3333-4333-8333-333333333333"
    static let shop = "44444444-4444-4444-8444-444444444444"
    static let occurrence = "55555555-5555-4555-8555-555555555555"
    private let lock = NSRecursiveLock()
    private var revision = 2
    private let quoteObservedAt = Date().addingTimeInterval(-60)
    private let quoteExpiresAt = Date().addingTimeInterval(3600)
    private var meal: [String:Any] = ["title":"Fixture shared soup","day":"2026-11-05","kind":"dinner","portions":4,"protected":false]
    private var proposals: [[String:Any]] = []
    private var createdMeals: [[String:Any]] = []
    private var receipts: [String:[String:Any]] = [:]
    private var posts = 0
    private var ideas: [[String:Any]] = []
    private var proposalPosts = 0
    private var ideaWrites = 0
    private static let soupLine = "66666666-6666-4666-8666-666666666666"
    private static let chickpeaFact = "88888888-8888-4888-8888-888888888888"
    private var basket: [[String: Any]] = [["lineId": S26FixtureServer.soupLine, "originalItem": "Entered soup packs", "packs": 1, "unitPriceMinor": 500, "feeEligible": true]]
    private var trackedPage: [String: Any]?
    private var actionSources: [String: Any]?
    private var trackingCandidate: [String: Any]?
    private var acceptedPreview: [String: Any]?
    private var commandBytes: [String: Data] = [:]
    var ideaChanged: (@Sendable (Int) -> Void)?
    var changed: (@Sendable (Int,Int) -> Void)?
    func respond(_ request: URLRequest) throws -> (Int,Data) {
        lock.lock(); defer { lock.unlock() }
        guard ["s26-identity.invalid", "s26-household.invalid"].contains(request.url?.host ?? "") else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(buffer,count:n) }
        }
        let input = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
        let shopper = request.value(forHTTPHeaderField:"Authorization")?.contains("shopper") == true
        func json(_ value: Any, status: Int = 200) throws -> (Int,Data) { (status,try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) }
        func denied() throws -> (Int,Data) { try json(["error":["code":"unavailable"]],status:404) }
        if path == "/auth/v1/verify" {
            let role = (input["email"] as? String)?.contains("shopper") == true ? "shopper" : "planner"
            return try json(["access_token":"fixture-"+role,"refresh_token":"refresh-"+role,"expires_in":3600,"user":["id":"native-"+role,"email_confirmed_at":"date"]])
        }
        if path == "/auth/v1/user" { return try json(["id":shopper ? "native-shopper":"native-planner","email_confirmed_at":"date"]) }
        if path == "/v1/me/workspaces" { return try json(["workspaces":[["householdId":Self.household,"label":"Isolated household ideas","role":"contributor"]]]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":shopper ? "shopper-device":"planner-device","deviceToken":shopper ? "shopper-token":"planner-token"],status:201) }
        if path.hasSuffix("/bootstrap") { return try json(["household":["id":Self.household,"label":"Isolated household ideas"],"memberId":shopper ? Self.shopper:Self.planner,"role":shopper ? "shopper":"contributor","shopId":Self.shop,"enrolled":true,"queueConsent":false,"capabilities":shopper ? ["shopper_commands","shopper_inbox","request_preview"]:["meal_proposals"]]) }
        let trackingPath = "/v1/households/\(Self.household)/shops/\(Self.shop)/demand/tracking"
        if path == trackingPath || path.hasPrefix(trackingPath + "/") {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-shopper",
                  request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            if path == trackingPath, request.httpMethod == "GET" { return try json(trackingPage()) }
            if path == trackingPath + "/action-sources", request.httpMethod == "POST" { return try json(sources(input)) }
            if path == trackingPath + "/candidates", request.httpMethod == "POST" { return try json(candidate(input)) }
            if path == trackingPath + "/previews", request.httpMethod == "POST" { return try json(accept(input)) }
            return try denied()
        }
        if path == "/v1/households/\(Self.household)/shops/\(Self.shop)/demand", request.httpMethod == "GET" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-shopper",
                  request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            if let trackedPage, let state = trackedPage["state"] as? [String: Any], let coverage = trackedPage["coverage"] as? [String: Any] {
                return try json(["schemaVersion": 1, "shopId": Self.shop, "shopRevision": revision, "authorityEpoch": 1,
                    "status": "enabled", "graph": state["graph"]!, "graphDigest": trackedPage["basisDigest"]!,
                    "totals": coverage["trackedSubtotals"]!, "legacySources": NSNull()])
            }
            // Omitted catalog means unavailable, not an assertion of no meal sources.
            return try json(["schemaVersion": 1, "shopId": Self.shop, "shopRevision": revision,
                             "authorityEpoch": 1, "status": "legacy", "graph": NSNull(), "totals": []])
        }
        if path.hasSuffix("/inbox") { return try json(["requests":[],"nextCursor":NSNull()]) }
        if path.hasSuffix("/requests/mine") { return try json(["requests":[],"nextCursor":NSNull()]) }
        let occurrence: [String:Any] = ["occurrenceId":Self.occurrence,"revision":2,"meal":meal]
        let projectedMeals = [occurrence] + createdMeals
        if path.hasSuffix("/meal-plan/ideas") { return try ideaResponse(input, method: request.httpMethod, shopper: shopper) }
        if path.hasSuffix("/meal-plan/changes"), request.httpMethod == "POST" {
            proposalPosts += 1; changed?(proposalPosts, posts)
            guard !shopper, let id = input["proposalId"] as? String, input["shopRevision"] as? Int == revision,
                  input["baseMealRevision"] is NSNull,
                  let approvedID = input["approvedIdeaId"] as? String,
                  let approved = ideas.first(where: { ($0["ideaId"] as? String)?.lowercased() == approvedID.lowercased() }),
                  approved["state"] as? String == "approved", approved["revision"] as? Int == input["approvedIdeaRevision"] as? Int else { return try denied() }
            try JSONDecoder().decode(SharedMealChangeRequest.self, from: bytes).validate()
            if !proposals.contains(where: { ($0["proposalId"] as? String) == id }) { proposals.append(["proposalId":id,"request":input,"original":NSNull(),"state":"pending"]) }
            changed?(proposalPosts,posts)
            return try json(["saved":true,"proposalId":id])
        }
        if path.hasSuffix("/meal-plan/changes") { return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"phase":"draft","shopper":shopper,"meals":projectedMeals,"proposals":proposals]) }
        if path.hasSuffix("/meal-plan") { return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"shopper":shopper,"plannerId":Self.planner,"adults":[["id":Self.planner,"label":"Fixture planner"]],"meals":projectedMeals,"proposals":[]]) }
        if path.hasSuffix("/shops/"+Self.shop) {
            guard shopper else { return try denied() }
            let quote = try ShopperQuote(scope:"wholeCheckout",complete:true,capMinor:1000,capScope:"wholeCheckout",fee:.fixed(0),taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:quoteObservedAt,expiresAt:quoteExpiresAt)
            return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"phase":"draft","meals":projectedMeals,"quote":try JSONSerialization.jsonObject(with:JSONEncoder().encode(quote)),"lines":basket])
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"77777777-7777-4777-8777-777777777777","expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            guard shopper, request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            if let receipt = receipts[key] {
                guard commandBytes[key] == bytes else { return try denied() }
                return try json(receipt)
            }
            guard let acceptedPreview, let trackingCandidate,
                  let action = trackingCandidate["action"] as? [String: Any], var expected = action["body"] as? [String: Any],
                  let body = input["body"] as? [String: Any], input["kind"] as? String == "shop.patch",
                  input["shopId"] as? String == Self.shop,
                  input["base"] as? [String: Int] == ["shopRevision": revision, "authorityEpoch": 1],
                  let expires = acceptedPreview["expiresAt"] as? String,
                  ISO8601DateFormatter().date(from: expires).map({ $0 > Date() }) == true else { return try denied() }
            expected["demandReview"] = ["previewId": acceptedPreview["previewId"]!, "previewDigest": acceptedPreview["previewDigest"]!, "trackingVersion": 2]
            guard NSDictionary(dictionary: expected).isEqual(to: body) else { return try denied() }
            let typed = try decode(SharedTrackingAction.self, action), index = try proposalIndex(typed)
            guard case .patch(let patch) = typed.command, let edit = patch.mealEdit, let next = edit.meal,
                  let after = trackingCandidate["after"] as? [String: Any],
                  let disclosure = trackingCandidate["disclosure"] as? [String: Any],
                  let pickup = disclosure["pickup"] as? [String: Any], let money = disclosure["money"] as? [String: Any] else { return try denied() }
            proposals[index]["state"] = "applied"
            revision += 1; posts += 1
            createdMeals.append(["occurrenceId": edit.occurrenceId.string, "revision": revision, "meal": try wire(next)])
            basket = try patch.lines.map { try wire($0) as! [String: Any] }
            trackedPage = ["schemaVersion": 2, "shopId": Self.shop, "shopRevision": revision, "authorityEpoch": 1,
                "status": "enabled", "state": after, "projection": NSNull(), "basisDigest": pickup["stateDigest"]!,
                "coverage": pickup["coverage"]!, "checkout": money["after"]!, "freezeReview": NSNull()]
            _ = try decode(SharedTrackingPage.self, trackedPage!)
            let receipt: [String: Any] = ["operationId": UUID().uuidString.lowercased(), "kind": "shop.patch", "shopId": Self.shop,
                "shopRevision": revision, "authorityEpoch": 1, "disposition": "patched"]
            receipts[key] = receipt; commandBytes[key] = bytes; changed?(proposalPosts, posts); return try json(receipt)
        }
        return try denied()
    }
    // One fixed first-adoption scenario, not a replacement service reducer. The
    // original soup basket stays legacy until the shopper accepts a real v2 review.
    private func wire<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    private func trackingPage() throws -> [String: Any] {
        if let trackedPage { return trackedPage }
        return try ModelTrackingReadFixture.page(household: Self.household, shop: Self.shop, revision: revision,
            basket: basket, checkout: ModelTrackingReadFixture.budget(500, cap: 1000))
    }
    private func proposalIndex(_ action: SharedTrackingAction) throws -> Int {
        guard case .patch(let patch) = action.command, let edit = patch.mealEdit, let id = edit.changeProposalId,
              edit.baseMealRevision == nil, edit.proposalId == nil,
              let index = proposals.firstIndex(where: { ($0["proposalId"] as? String)?.lowercased() == id.string }),
              proposals[index]["state"] as? String == "pending",
              !createdMeals.contains(where: { ($0["occurrenceId"] as? String)?.lowercased() == edit.occurrenceId.string }) else { throw ClientError.invalidResponse }
        let proposed = try decode(SharedMealChangeRequest.self, proposals[index]["request"]!)
        guard proposed.baseMealRevision == nil, proposed.occurrenceId == edit.occurrenceId.uuid, proposed.meal == edit.meal,
              patch.lines.count == 2, patch.lines[0].lineId == Self.soupLine,
              patch.lines[0].originalItem == "Entered soup packs", patch.lines[0].packs == 1, patch.lines[0].unitPriceMinor == 500,
              patch.lines[1].originalItem == "Chickpeas", patch.lines[1].packs == 1, patch.lines[1].unitPriceMinor == nil else { throw ClientError.invalidResponse }
        return index
    }
    private struct SourceInput: Decodable { let base: SharedTrackingActionSourceBase; let action: SharedTrackingAction }
    private func sources(_ input: [String: Any]) throws -> [String: Any] {
        let request = try decode(SourceInput.self, input), page = try decode(SharedTrackingPage.self, trackingPage())
        guard Set(input.keys) == ["base", "action"], trackedPage == nil,
              request.base == (try SharedTrackingActionSourceBase(page: page)) else { throw ClientError.invalidResponse }
        _ = try proposalIndex(request.action)
        guard case .patch(let patch) = request.action.command, let edit = patch.mealEdit, let meal = edit.meal,
              let planning = meal.planning, planning.ingredients.count == 1, planning.groups.isEmpty, planning.bindings?.isEmpty != false,
              let ingredient = planning.ingredients.first, ingredient.name == "Chickpeas", let amount = ingredient.quantity,
              amount.amount.numerator == 1, amount.amount.denominator == 2, amount.unit == "cup", !meal.protected else { throw ClientError.invalidResponse }
        let source = SharedDemandSource.meal(occurrenceId: edit.occurrenceId, ingredientId: .init(ingredient.id), groupId: nil, bindingId: nil)
        let restrictions: [[String: Any]] = (planning.exclusions ?? []).map {
            ["occurrenceId": edit.occurrenceId.string, "ingredientId": NSNull(), "label": $0, "resolution": ["kind": "unresolved"]]
        } + ingredient.exclusions.map {
            ["occurrenceId": edit.occurrenceId.string, "ingredientId": ingredient.id.uuidString.lowercased(), "label": $0, "resolution": ["kind": "unresolved"]]
        }
        let quantity: [String: Any] = ["amount": ["numerator": "1", "denominator": "2"], "unit": "cup",
            "originalLiteral": amount.originalLiteral, "confirmedConversion": NSNull()]
        let fact: [String: Any] = ["id": Self.chickpeaFact, "revision": revision + 1, "source": try wire(source), "sourceLabel": meal.title,
            "productName": ingredient.name, "originalText": ingredient.name, "originalQuantityText": amount.originalLiteral,
            "quantity": quantity, "sourceExclusions": restrictions, "requiredLineId": NSNull()]
        let response: [String: Any] = ["schemaVersion": 2, "shopId": Self.shop, "base": try wire(request.base),
            "normalizedAction": try wire(request.action), "actionDigest": String(repeating: "c", count: 64), "sources": [fact]]
        let catalog = try decode(SharedTrackingActionSources.self, response)
        try catalog.validate(page: page, action: request.action.command)
        actionSources = response; trackingCandidate = nil; acceptedPreview = nil
        return response
    }
    private struct AdoptionInput: Decodable {
        let mode: String; let base: SharedTrackingActionSourceBase; let action: SharedTrackingAction
        let change: SharedDemandChange; let packs: [SharedDemandPackReview]
    }
    private func candidate(_ input: [String: Any]) throws -> [String: Any] {
        guard Set(input.keys) == ["mode", "base", "action", "change", "packs"], let actionSources, trackedPage == nil else { throw ClientError.invalidResponse }
        let intent = try decode(AdoptionInput.self, input), catalog = try decode(SharedTrackingActionSources.self, actionSources)
        guard intent.mode == "adopt", intent.base == catalog.base, (try SharedTrackingAction(intent.action.command)) == catalog.normalizedAction,
              case .patch(let patch) = intent.action.command, let edit = patch.mealEdit, edit.meal != nil,
              intent.change.lines.count == 2, intent.change.contributions.count == 2, intent.change.edges.isEmpty,
              intent.change.removeSourceIds.isEmpty, intent.change.removeEdgeIds.isEmpty,
              intent.change.quantifyReservationIds?.isEmpty != false, intent.change.clarifyReservationProductIds?.isEmpty != false,
              intent.packs.count == 2, intent.packs.allSatisfy({ $0.usablePerPack == nil && $0.acceptUnresolved }),
              let source = catalog.sources.first,
              let chickpea = intent.change.contributions.first(where: { $0.id.string == Self.chickpeaFact }),
              let soup = intent.change.contributions.first(where: { $0.lineId.string == Self.soupLine }),
              case .manual = soup.source, soup.quantity == nil, soup.productName == "Entered soup packs", soup.originalText == "Entered soup packs",
              chickpea.lineId.string == patch.lines[1].lineId, chickpea.source == source.fact.source, chickpea.quantity == source.fact.quantity,
              chickpea.originalText == source.fact.originalText, chickpea.sourceExclusions == source.fact.sourceExclusions,
              intent.change.lines.first(where: { $0.id == chickpea.lineId })?.unit == .cup,
              intent.change.lines.first(where: { $0.id == soup.lineId })?.unit == .count else { throw ClientError.invalidResponse }
        _ = try proposalIndex(intent.action)
        let graph = SharedDemandGraph(householdId: .init(UUID(uuidString: Self.household)!), shopId: .init(UUID(uuidString: Self.shop)!), revision: 1,
            lines: intent.change.lines, contributions: intent.change.contributions, edges: [],
            usedIds: intent.change.lines.map(\.id) + intent.change.contributions.map(\.id))
        let totals: [[String: Any]] = graph.lines.map { line in
            let row = graph.contributions.first { $0.lineId == line.id }!
            return ["lineId": line.id.string, "unit": line.unit.rawValue,
                "quantity": row.quantity == nil ? NSNull() : ["numerator": "1", "denominator": "2"] as Any, "activeContributionIds": [row.id.string]]
        }
        var fact = (actionSources["sources"] as! [[String: Any]])[0]; fact.removeValue(forKey: "productName")
        var afterMoney = ModelTrackingReadFixture.budget(nil, cap: 1000); afterMoney["lowerBoundMinor"] = 500
        let afterPage = try ModelTrackingReadFixture.page(household: Self.household, shop: Self.shop, revision: revision,
            basket: patch.lines.map { try wire($0) as! [String: Any] }, graph: graph, totals: totals, checkout: afterMoney,
            catalog: [fact], bindings: [["factId": Self.chickpeaFact, "contributionId": Self.chickpeaFact]])
        var state = afterPage["state"] as! [String: Any]
        state["packReviews"] = try wire(intent.packs)
        let pickup: [String: Any] = ["stateDigest": String(repeating: "d", count: 64), "catalogDigest": String(repeating: "e", count: 64),
            "priceBasisDigest": String(repeating: "f", count: 64), "coverageStatement": "tracked_subtotals_only_no_complete_coverage_or_free_unbound_supply",
            "coverage": afterPage["coverage"]!, "unbound": [], "unpricedBasketIds": [patch.lines[1].lineId],
            "unresolvedPackIds": intent.packs.map { $0.lineId.string }, "basket": state["basket"]!, "packReviews": try wire(intent.packs)]
        let action = try wire(catalog.normalizedAction) as! [String: Any]
        let actionBody = action["body"] as! [String: Any], actionEdit = actionBody["mealEdit"] as! [String: Any]
        let disclosure: [String: Any] = ["changes": ["kind": "mealActionChange", "mealChange": ["occurrenceId": edit.occurrenceId.string,
            "before": NSNull(), "after": ["revision": revision + 1, "meal": actionEdit["meal"]!]], "transferredChanges": []],
            "pickup": pickup, "money": ["before": ModelTrackingReadFixture.budget(500, cap: 1000), "after": afterMoney]]
        let result: [String: Any] = ["schemaVersion": 2, "candidateId": UUID().uuidString.lowercased(), "candidateDigest": String(repeating: "a", count: 64),
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)), "action": action, "after": state, "disclosure": disclosure]
        _ = try decode(SharedTrackingCandidate.self, result)
        trackingCandidate = result; acceptedPreview = nil
        return result
    }
    private func accept(_ input: [String: Any]) throws -> [String: Any] {
        guard let trackingCandidate, input["candidateId"] as? String == trackingCandidate["candidateId"] as? String,
              input["candidateDigest"] as? String == trackingCandidate["candidateDigest"] as? String,
              let acknowledged = input["acknowledgedDisclosure"] as? [String: Any],
              let disclosure = trackingCandidate["disclosure"] as? [String: Any], NSDictionary(dictionary: acknowledged).isEqual(to: disclosure),
              input["acceptUnknown"] as? Bool == true, input["acceptOverage"] as? Bool == false else { throw ClientError.invalidResponse }
        let preview: [String: Any] = ["schemaVersion": 2, "previewId": trackingCandidate["candidateId"]!, "previewDigest": String(repeating: "b", count: 64),
            "trackingVersion": 2, "expiresAt": trackingCandidate["expiresAt"]!, "action": trackingCandidate["action"]!, "disclosure": disclosure,
            "moneyAcknowledgments": ["acceptOverage": false, "acceptUnknown": true]]
        _ = try decode(SharedTrackingPreview.self, preview); acceptedPreview = preview
        return preview
    }

    // Minimal intercepted fixture response. The real API's arithmetic has separate integration evidence.
    private func ideaResponse(_ input: [String:Any], method: String?, shopper: Bool) throws -> (Int,Data) {
        func json(_ value: Any) throws -> (Int,Data) { (200, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        if method != "POST" {
            return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"shopper":shopper,"ideas":ideas])
        }
        ideaWrites += 1; ideaChanged?(ideaWrites)
        let bytes = try JSONSerialization.data(withJSONObject: input)
        let request = try JSONDecoder().decode(SharedMealIdeaWrite.self, from: bytes)
        try request.draft.validate()
        let key = request.clientKey.uuidString
        if let receipt = receipts[key] { return try json(receipt) }
        guard !shopper, request.shopRevision == revision, request.authorityEpoch == 1, request.grantRevision == 1,
              let draft = input["draft"] as? [String:Any], let ingredients = draft["ingredients"] as? [[String:Any]] else { throw URLError(.badServerResponse) }
        let index = ideas.firstIndex { ($0["ideaId"] as? String)?.lowercased() == request.ideaId.uuidString.lowercased() }
        guard request.baseRevision == index.flatMap({ ideas[$0]["revision"] as? Int }) else { throw URLError(.badServerResponse) }
        if request.action == "approve" {
            guard request.reviewedHouseholdEvidence, let index,
                  NSDictionary(dictionary: ideas[index]["draft"] as? [String:Any] ?? [:]).isEqual(to: draft) else { throw URLError(.badServerResponse) }
        }
        func amount(_ value: Any?) throws -> Rational? {
            if let n = value as? Int { return try Rational(Int64(n)) }
            guard let fraction = value as? [String:Int], let n = fraction["numerator"], let d = fraction["denominator"] else { return nil }
            return try Rational(Int64(n), Int64(d))
        }
        func wire(_ value: Rational?) -> Any {
            guard let value else { return NSNull() }
            if value.denominator == 1 { return Int(value.numerator) }
            return ["numerator":Int(value.numerator),"denominator":Int(value.denominator)]
        }
        var complete = true
        let previews = try ingredients.map { item -> [String:Any] in
            let reserved = try (item["reservations"] as? [[String:Any]] ?? []).reduce(Rational.zero) { sum, row in
                guard let value = try amount(row["amount"]) else { throw URLError(.badServerResponse) }; return try sum.adding(value)
            }
            let required = try amount(item["required"]), stock = try amount(item["stock"]), pack = try amount(item["pack"])
            var remaining: Rational?, shortage: Rational?, packs: Int?
            if let stock { remaining = max(.zero, try stock.subtracting(reserved)) }
            if let required, let remaining { shortage = max(.zero, try required.subtracting(remaining)) }
            if let shortage, let pack, let numerator = item["usableNumerator"] as? Int, let denominator = item["usableDenominator"] as? Int {
                let usable = try pack.multiplied(by: Rational(Int64(numerator), Int64(denominator)))
                if usable > .zero { let ratio = try shortage.divided(by: usable); packs = Int((ratio.numerator + ratio.denominator - 1) / ratio.denominator) }
            }
            complete = complete && packs != nil
            return ["ingredientId":item["id"]!,"excluded":false,"reserved":wire(reserved),"remaining":wire(remaining),"shortage":wire(shortage),"wholePacks":packs.map { $0 as Any } ?? NSNull(),"unresolvedPrice":true]
        }
        guard request.action != "approve" || complete else { throw URLError(.badServerResponse) }
        let nextRevision = (request.baseRevision ?? 0) + 1, state = request.action == "approve" ? "approved" : "draft"
        let idea: [String:Any] = ["ideaId":request.ideaId.uuidString,"revision":nextRevision,"actorId":Self.planner,"state":state,"draft":draft,"preview":["canApprove":complete,"ingredients":previews]]
        if let index { ideas[index] = idea } else { ideas.append(idea) }
        let receipt: [String:Any] = ["saved":true,"ideaId":request.ideaId.uuidString,"revision":nextRevision,"state":state]
        receipts[key] = receipt; return try json(receipt)
    }

}
private final class S26FixtureProtocol: URLProtocol {
    static var server: S26FixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@MainActor private final class S26FixtureState: ObservableObject {
    @Published var planner: HouseholdModel?
    @Published var shopper: HouseholdModel?
    @Published var proposals = 0
    @Published var applications = 0
    @Published var ideaWrites = 0
    @Published var failure: String?
    private let server = S26FixtureServer()
    func start() async {
        guard planner == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--shared-idea-fixture") else { return }
        do {
            S26FixtureProtocol.server = server
            server.ideaChanged = { [weak self] count in Task { @MainActor in self?.ideaWrites = count } }
            server.changed = { [weak self] proposed,applied in Task { @MainActor in self?.proposals = proposed; self?.applications = applied } }
            planner = try await make(role:"planner"); shopper = try await make(role:"shopper")
        } catch { failure = "Fixture setup failed" }
    }
    private func make(role: String) async throws -> HouseholdModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [S26FixtureProtocol.self]
        let transport = HTTPTransport(session:URLSession(configuration:config))
        let auth = AdultAuth(configuration:try .init(projectURL:URL(string:"https://s26-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:S26FixtureVault(),transport:transport)
        let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://s26-household.invalid")!),auth:auth,deviceVault:S26FixtureVault(),transport:transport)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/S26-"+UUID().uuidString).appendingPathComponent("outbox.json")
        let model = HouseholdModel(auth:auth,service:service,outboxURL:url,deletionVault:S26FixtureVault(),exitVault:S26FixtureVault())
        model.email = role+"@example.invalid"; model.code = "123456"; await model.verifyCode()
        guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
        model.keepLocalPrivate = true; await model.join(workspace)
        guard model.projection != nil else { throw ClientError.invalidResponse }
        if role == "shopper" { await model.sharedShop?.load() }
        return model
    }
}
struct S26SharedMealIdeaFixtureRoot: View {
    @StateObject private var state = S26FixtureState()
    @State private var shopperMode = false
    var body: some View {
        VStack(spacing: 4) {
            Text("Fixture idea writes: \(state.ideaWrites)").accessibilityIdentifier("fixture.s26.ideas")
            Text("Fixture meal proposals: \(state.proposals)").accessibilityIdentifier("fixture.s26.proposals")
            Text("Fixture basket writes: \(state.applications)").accessibilityIdentifier("fixture.s26.basket")
            if let planner = state.planner, let shopper = state.shopper {
                Button("Switch to assigned shopper") { shopperMode = true }.accessibilityIdentifier("fixture.s26.switch")
                NavigationStack {
                    if shopperMode { DinnerSharedPlanningEntry(household: shopper) }
                    else {
                        List {
                            NavigationLink("Open household dinner ideas") { SharedMealIdeasView(household: planner) }
                                .accessibilityIdentifier("fixture.s26.open")
                        }.navigationTitle("Household idea fixture")
                    }
                }.id(shopperMode)
            } else if let failure = state.failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated household idea fixture") }
        }.task { await state.start() }
    }
}
#endif
