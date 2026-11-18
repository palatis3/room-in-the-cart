#if DEBUG
import Foundation
import HouseholdClient

/// Read-only v2 projection for these fixed HTTP fixtures. Totals and catalog
/// facts are supplied by each scenario; this helper does not implement a reducer.
/// Digest strings are opaque fixture tokens, never production digest calculations.
enum ModelTrackingReadFixture {
    static func page(household: String, shop: String, revision: Int, basket: [[String: Any]],
                     graph: SharedDemandGraph? = nil, totals: [[String: Any]] = [],
                     checkout: [String: Any], recovery: Bool = false,
                     catalog: [[String: Any]] = [], bindings: [[String: Any]] = []) throws -> [String: Any] {
        let empty = SharedDemandGraph(householdId: .init(UUID(uuidString: household)!), shopId: .init(UUID(uuidString: shop)!), revision: 0, lines: [], contributions: [], edges: [], usedIds: [])
        let current = graph ?? empty
        let rows: [[String: Any]] = basket.map { ["id": $0["lineId"]!, "name": $0["originalItem"]!, "packs": $0["packs"]!, "priceMinor": $0["unitPriceMinor"] ?? NSNull(), "feeEligible": $0["feeEligible"]!] }
        let legacy = graph == nil ? rows.map { $0["id"] as! String } : []
        let bound = Set(bindings.compactMap { $0["factId"] as? String })
        let unbound = catalog.filter { !bound.contains($0["id"] as! String) }.map { ["factId": $0["id"]!, "transferred": NSNull()] }
        let packs: [[String: Any]] = current.lines.filter { $0.trashedAt == nil }.map { ["lineId": $0.id.string, "usablePerPack": NSNull(), "acceptUnresolved": true] }
        var state: [String: Any] = ["schemaVersion": 2, "authorityEpoch": 1, "privacyRevision": recovery ? 1 : 0, "quoteDigest": String(repeating: "a", count: 64),
            "graph": try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)), "basket": rows, "catalog": catalog, "bindings": bindings, "unbound": unbound, "legacyLineIds": legacy, "packReviews": packs]
        let protected = catalog.filter { ($0["source"] as? [String: Any])?["kind"] as? String == "reservation" && !bound.contains($0["id"] as! String) }.map { $0["id"]! }
        let coverage: [String: Any] = ["status": !legacy.isEmpty || !unbound.isEmpty ? "partial" : totals.contains { $0["quantity"] is NSNull } ? "unknown" : "tracked", "trackedSubtotals": totals,
            "completeFoodCoverage": false, "unboundFactIds": unbound.map { $0["factId"]! }, "untrackedBasketIds": legacy, "protectedUnboundFactIds": protected, "allocatableUnboundFactIds": []]
        var projection: Any = NSNull()
        if recovery {
            state.removeValue(forKey: "packReviews")
            projection = ["schemaVersion": 1, "status": "reviewRequired", "invalidatedStateDigest": String(repeating: "d", count: 64), "previousPrivacyRevision": 0, "state": state]
        }
        return ["schemaVersion": 2, "shopId": shop, "shopRevision": revision, "authorityEpoch": 1, "status": recovery ? "reviewRequired" : graph == nil ? "legacy" : "enabled",
            "state": recovery ? NSNull() : state as Any, "projection": projection, "basisDigest": String(repeating: "b", count: 64), "coverage": recovery ? NSNull() : coverage as Any,
            "checkout": checkout, "freezeReview": NSNull()]
    }
    static func budget(_ amount: Int?, cap: Int) -> [String: Any] {
        ["currency": "USD", "totalMinor": amount as Any? ?? NSNull(), "overCapMinor": amount.map { max(0, $0-cap) } as Any? ?? NSNull(), "headroomMinor": amount.map { max(0, cap-$0) } as Any? ?? NSNull(),
         "status": amount.map { $0 > cap ? "overCap" : "withinCap" } ?? "unresolved", "scope": "wholeCheckout", "missing": amount == nil ? ["line_price"] : [],
         "lowerBoundMinor": amount ?? 0, "upperBoundMinor": amount as Any? ?? NSNull(), "wholeCheckoutWithinCap": amount.map { $0 <= cap } ?? false]
    }
}

/// Fictional, isolated transport shared by S23 model tests and its opt-in UI fixture.
/// Never accepts a real host or sends network traffic.
final class S23DuplicateFixtureServer: @unchecked Sendable {
    static let householdID = "a1111111-1111-4111-8111-111111111111"
    static let memberID = "a2222222-2222-4222-8222-222222222222"
    static let shopID = "a3333333-3333-4333-8333-333333333333"
    static let samID = "a4444444-4444-4444-8444-444444444441"
    static let wrapsID = "a4444444-4444-4444-8444-444444444442"
    static let leeID = "a4444444-4444-4444-8444-444444444443"
    static let patID = "a4444444-4444-4444-8444-444444444444"
    static let lineID = "a7777777-7777-4777-8777-777777777777"
    private let lock = NSRecursiveLock()
    private var revision = 1
    private var decisions: [String: [String: Any]] = [:]
    private var receipts: [String: [String: Any]] = [:]
    private var statuses: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var clarifications: [String: String] = [:]
    private var applied: [String] = []
    private var previews = 0
    private let pageBoundary: Bool
    private let basketName: String
    private let mealNames: [String]
    private let supportsSameItem: Bool
    enum PairMode { case off, available, olderServer, unresolvedBudget, mismatchedEvidence, changedBudget, nonzeroDelta, requiresOverage, requiresUnknown }
    private let pairMode: PairMode
    private var activePair: (operation: String, relationship: String)?
    private var supportsPairs: Bool { pairMode != .off && pairMode != .olderServer }
    private let repeatsBasketLine: Bool
    init(pageBoundary: Bool = false, basketName: String = "Cereal already in the basket", mealNames: [String] = [], repeatsBasketLine: Bool = false, supportsSameItem: Bool = true, pairMode: PairMode = .off) {
        self.pairMode = pairMode
        self.supportsSameItem = supportsSameItem
        self.repeatsBasketLine = repeatsBasketLine
        self.mealNames = mealNames
        self.pageBoundary = pageBoundary
        self.basketName = basketName
        if pairMode != .off { revisions[Self.leeID] = 4 }
    }
    var changed: ((Int) -> Void)?
    var commandCount: Int { lock.lock(); defer { lock.unlock() }; return applied.count }
    var previewCount: Int { lock.lock(); defer { lock.unlock() }; return previews }
    var appliedRequestIDs: [String] { lock.lock(); defer { lock.unlock() }; return applied }

    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard ["s23-identity.invalid", "s23-household.invalid"].contains(request.url?.host ?? "") else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
        }
        let input = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        func json(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        if path == "/auth/v1/verify" { return try json(["access_token":"fixture-access", "refresh_token":"fixture-refresh", "expires_in":3600, "user":["id":"s23-fictional-adult", "email_confirmed_at":"date"]]) }
        if path == "/auth/v1/user" { return try json(["id":"s23-fictional-adult", "email_confirmed_at":"date"]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":"fixture-device", "deviceToken":"fixture-device-token"]) }
        if path.hasSuffix("/bootstrap") {
            return try json(["household":["id":Self.householdID, "label":"S23 Fictional Household"], "memberId":Self.memberID, "role":"shopper", "shopId":Self.shopID, "enrolled":true, "queueConsent":false, "capabilities":["shopper_inbox", "request_preview", "shopper_commands"] + (supportsSameItem ? ["request_same_item"] : []) + (supportsPairs ? ["request_pair_review"] : [])])
        }
        if path.hasSuffix("/inbox") {
            let cursor = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "cursor" }?.value
            if pageBoundary {
                let rows = requestRows()
                return try json(["requests":cursor == nil ? Array(rows.prefix(2)) : Array(rows.suffix(2)), "nextCursor":cursor == nil ? Self.wrapsID as Any : NSNull()])
            }
            return try json(["requests":requestRows(), "nextCursor":NSNull()])
        }
        if path.hasSuffix("/shops/" + Self.shopID) {
            let quote = try ShopperQuote(scope:"wholeCheckout", complete:true, capMinor:3800, capScope:"wholeCheckout", fee:.fixed(0), taxesMinor:0, depositsMinor:0, discountsMinor:0,
                observedAt:Date(timeIntervalSince1970:1_793_718_000), expiresAt:Date(timeIntervalSince1970:4_070_908_800))
            let line: [String: Any] = ["lineId": Self.lineID, "originalItem": basketName, "packs": 1, "unitPriceMinor": 349, "feeEligible": true]
            return try json(["shopId":Self.shopID, "shopRevision":revision, "authorityEpoch":1, "phase":"draft", "quote":try JSONSerialization.jsonObject(with:JSONEncoder().encode(quote)),
                "lines":pairMode != .off ? [] : (repeatsBasketLine ? [line, line] : [line])])
        }
        if request.httpMethod == "GET", path.hasSuffix("/shops/" + Self.shopID + "/demand/tracking") {
            let basket: [[String: Any]] = pairMode == .off ? [["lineId": Self.lineID, "originalItem": basketName, "packs": 1, "unitPriceMinor": 349, "feeEligible": true]] : []
            let catalog: [[String: Any]] = requestRows().filter { statuses[$0["requestId"] as! String] == "added" }.map { row in
                let id = row["requestId"] as! String
                return ["id": id, "revision": (revisions[id] ?? 2)-1, "source": ["kind": "request", "requestId": id, "appliedRequestRevision": (revisions[id] ?? 2)-1], "sourceLabel": "Request", "originalText": row["originalItem"]!, "originalQuantityText": row["ownQuantity"]!, "quantity": NSNull(), "sourceExclusions": [], "requiredLineId": Self.lineID]
            }
            let meals: [[String: Any]] = mealNames.enumerated().map { index, name in
                let ingredient = String(format: "b0000000-0000-4000-8000-%012d", index)
                return ["id": ingredient, "revision": 1,
                        "source": ["kind": "meal", "occurrenceId": Self.wrapsID, "ingredientId": ingredient,
                                   "groupId": NSNull(), "bindingId": NSNull()],
                        "sourceLabel": "Breakfast", "originalText": name, "originalQuantityText": "1 bowl",
                        "quantity": NSNull(), "sourceExclusions": [], "requiredLineId": NSNull()]
            }
            return try json(ModelTrackingReadFixture.page(household: Self.householdID, shop: Self.shopID, revision: revision, basket: basket, checkout: budget(pairMode == .off ? 349 : 0), catalog: catalog + meals))
        }
        if request.httpMethod == "GET", path.hasSuffix("/shops/" + Self.shopID + "/demand") {
            return try json(["schemaVersion":1,"shopId":Self.shopID,"shopRevision":revision,"authorityEpoch":1,"status":"legacy","graph":NSNull(),"totals":[]])
        }
        if path.hasSuffix("/previews"), let requestID = input["requestId"] as? String,
           let decision = input["decision"] as? [String: Any], let choice = decision["choice"] as? String {
            guard requestRows().contains(where: { $0["requestId"] as? String == requestID }) else { throw URLError(.badServerResponse) }
            previews += 1
            let previewID = UUID().uuidString.lowercased()
            decisions[previewID] = ["requestId":requestID, "decision":decision]
            let line = decision["line"] as? [String: Any]
            let delta: Int? = choice == "add" ? (line?["unitPriceMinor"] as? Int).map { $0 * (line?["packs"] as? Int ?? 1) } : 0
            let before = pairMode == .off ? 3720 : 0
            let total = delta.map { before + $0 }
            var result: [String: Any] = ["previewId":previewID, "expiresAt":"2099-01-01T00:00:00Z", "shopRevision":revision, "authorityEpoch":1, "requestRevision":revisions[requestID] ?? 1, "choice":choice,
                "before":budget(before), "after":budget(total), "changeMinor":delta as Any? ?? NSNull(), "requiresOverageAcceptance":total.map { $0 > 3800 } ?? false, "requiresUnknownAcceptance":total == nil]
            if choice == "reviewRequestPair" || choice == "undoRequestPair" {
                guard input["base"] as? [String: Int] == ["shopRevision": revision, "authorityEpoch": 1, "requestRevision": revisions[requestID] ?? 1]
                else { throw URLError(.badServerResponse) }
                var evidence = try pairEvidence(for: requestID, decision: decision)
                switch pairMode {
                case .unresolvedBudget:
                    result["before"] = budget(nil)
                    result["after"] = budget(nil)
                    result["changeMinor"] = NSNull()
                case .mismatchedEvidence: evidence["quantity"] = "Changed since review"
                case .changedBudget: result["after"] = budget(before + 1)
                case .nonzeroDelta: result["changeMinor"] = 1
                case .requiresOverage: result["requiresOverageAcceptance"] = true
                case .requiresUnknown: result["requiresUnknownAcceptance"] = true
                default: break
                }
                result["requestPairEvidence"] = evidence
            }
            if choice == "sameItem" {
                guard let target = decision["target"] as? [String: Any], target["kind"] as? String == "meal",
                      target["factRevision"] as? Int == 1,
                      let index = mealNames.indices.first(where: {
                          String(format: "b0000000-0000-4000-8000-%012d", $0) == target["factId"] as? String
                      }) else { throw URLError(.badServerResponse) }
                result["sameItemEvidence"] = ["item":mealNames[index],"quantity":"1 bowl","sourceLabel":"Breakfast","exclusions":[]] as [String: Any]
            }
            return try json(result)
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"a6666666-6666-4666-8666-666666666666", "expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            if let receipt = receipts[key] { return try json(receipt) }
            guard let kind = input["kind"] as? String, let body = input["body"] as? [String: Any],
                  let requestID = body["requestId"] as? String else { throw URLError(.badServerResponse) }
            if kind == "request.clarify", let question = body["question"] as? String {
                guard requestRows().contains(where: { $0["requestId"] as? String == requestID && $0["ownActionAllowed"] as? Bool == true }) else { throw URLError(.badServerResponse) }
                clarifications[requestID] = question
                return try json(record(key:key,kind:kind,requestID:requestID,disposition:"clarified"))
            }
            guard kind == "request.apply", let previewID = body["previewId"] as? String,
                  let preview = decisions[previewID], preview["requestId"] as? String == requestID,
                  let decision = preview["decision"] as? [String: Any], let choice = decision["choice"] as? String else { throw URLError(.badServerResponse) }
            if choice == "reviewRequestPair" || choice == "undoRequestPair" {
                let evidence = try pairEvidence(for: requestID, decision: decision)
                guard input["base"] as? [String: Int] == ["shopRevision": revision, "authorityEpoch": 1, "requestRevision": revisions[requestID] ?? 1],
                      let relationship = evidence["relationship"] as? String else { throw URLError(.badServerResponse) }
                let operation = UUID().uuidString.lowercased()
                activePair = choice == "reviewRequestPair" ? (operation, relationship) : nil
                return try json(record(key: key, kind: kind, requestID: requestID, disposition: "pending",
                                       operation: operation, changesRequest: false))
            }
            let disposition: String
            switch choice {
            case "link":
                guard decision["lineId"] as? String == Self.lineID else { throw URLError(.badServerResponse) }
                disposition = "added"; revision += 1
            case "defer": disposition = "deferred"
            case "dismiss": disposition = "dismissed"
            case "handled", "sameItem": disposition = "handled"
            default: throw URLError(.unsupportedURL)
            }
            return try json(record(key:key,kind:kind,requestID:requestID,disposition:disposition))
        }
        throw URLError(.unsupportedURL)
    }

    private func record(key:String,kind:String,requestID:String,disposition:String,
                        operation: String = UUID().uuidString.lowercased(), changesRequest: Bool = true) -> [String: Any] {
        if changesRequest {
            revisions[requestID] = (revisions[requestID] ?? 1) + 1
            statuses[requestID] = disposition
        }
        applied.append(requestID)
        let receipt: [String: Any] = ["operationId":operation, "kind":kind, "shopId":Self.shopID, "shopRevision":revision, "authorityEpoch":1, "disposition":disposition, "requestId":requestID, "requestRevision":revisions[requestID] ?? 1]
        receipts[key] = receipt; changed?(applied.count)
        return receipt
    }

    private func pairEvidence(for requestID: String, decision: [String: Any]) throws -> [String: Any] {
        let rows = requestRows()
        guard supportsPairs, rows.count == 2,
              rows.contains(where: { $0["requestId"] as? String == requestID }),
              let other = rows.first(where: { $0["requestId"] as? String != requestID }),
              let otherID = other["requestId"] as? String, let otherRevision = other["revision"] as? Int
        else { throw URLError(.badServerResponse) }
        let relationship: String
        if decision["choice"] as? String == "undoRequestPair" {
            guard let activePair, decision["operationId"] as? String == activePair.operation
            else { throw URLError(.badServerResponse) }
            relationship = activePair.relationship
        } else {
            guard activePair == nil, decision["otherRequestId"] as? String == otherID,
                  decision["otherRequestRevision"] as? Int == otherRevision,
                  let value = decision["relationship"] as? String,
                  RequestPairRelationship(rawValue: value) != nil else { throw URLError(.badServerResponse) }
            relationship = value
        }
        return ["otherRequestId": otherID, "otherRequestRevision": otherRevision, "relationship": relationship,
                "item": other["originalItem"]!, "quantity": other["ownQuantity"]!, "authorAlias": other["authorAlias"]!]
    }

    private func budget(_ total: Int?) -> [String: Any] {
        ["currency":"USD", "totalMinor":total as Any? ?? NSNull(), "overCapMinor":total.map { max(0,$0-3800) } as Any? ?? NSNull(), "headroomMinor":total.map { max(0,3800-$0) } as Any? ?? NSNull(), "status":total.map { $0 > 3800 ? "overCap" : "withinCap" } ?? "unresolved", "scope":"wholeCheckout", "missing":total == nil ? ["line_price"] : [], "lowerBoundMinor":total ?? 0, "upperBoundMinor":total as Any? ?? NSNull(), "wholeCheckoutWithinCap":total.map { $0 <= 3800 } ?? false]
    }
    private func requestRows() -> [[String: Any]] {
        let examples = [(Self.samID,"Cereal","1 box for breakfasts","Sam","pending"),
         (Self.wrapsID,"Wraps","8 wraps for lunch","Alex","pending"),
         (Self.leeID,"CEREAL","2 boxes for the school snack drive","Lee","pending"),
         (Self.patID,"Cereal","1 box for the weekend","Pat","handled")]
        let rows = pairMode == .off ? examples : examples.filter { $0.0 == Self.samID || $0.0 == Self.leeID }
        return rows.enumerated().map { index, item in
            let status = statuses[item.0] ?? item.4
            var row: [String: Any] = ["requestId":item.0, "shopId":Self.shopID, "revision":revisions[item.0] ?? 1, "originalItem":item.1, "ownQuantity":item.2, "authorAlias":item.3,
                "authoredAt":"2026-11-03T15:00:0\(index)Z", "receivedAt":"2026-11-03T15:01:0\(index)Z", "route":status == "deferred" ? "next" : "current", "status":status,
                "ownActionAllowed":status == "pending" || status == "clarified", "clarification":clarifications[item.0] as Any? ?? NSNull()]
            if supportsPairs {
                let other = item.0 == Self.samID ? Self.leeID : Self.samID
                let pair = activePair.map { ["otherRequestId": other, "otherRequestRevision": revisions[other] ?? 1,
                                              "relationship": $0.relationship, "operationId": $0.operation] as [String: Any] }
                row["requestPairs"] = pair.map { [$0] } ?? []
            }
            return row
        }
    }
}

final class S23DuplicateFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
final class S23DuplicateFixtureProtocol: URLProtocol {
    static var server: S23DuplicateFixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            client?.urlProtocol(self, didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError:error) }
    }
    override func stopLoading() {}
}

@MainActor func s23DuplicateFixtureModel(server: S23DuplicateFixtureServer, outboxURL: URL) async throws -> HouseholdInboxModel {
    S23DuplicateFixtureProtocol.server = server
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [S23DuplicateFixtureProtocol.self]
    let transport = HTTPTransport(session:URLSession(configuration:configuration))
    let auth = AdultAuth(configuration:try .init(projectURL:URL(string:"https://s23-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:S23DuplicateFixtureVault(),transport:transport)
    _ = try await auth.verifyEmailCode(email:"s23-shopper@example.invalid",code:"123456")
    let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://s23-household.invalid")!),auth:auth,deviceVault:S23DuplicateFixtureVault(),transport:transport)
    let bootstrap = try await service.enroll(householdID:S23DuplicateFixtureServer.householdID)
    let model = HouseholdInboxModel(bootstrap:bootstrap,service:service,outbox:OperationOutbox(url:outboxURL),onAccessEnded:{})
    await model.load()
    return model
}
#endif
