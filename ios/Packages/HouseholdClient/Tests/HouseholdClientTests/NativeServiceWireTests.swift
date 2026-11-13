import Security
import XCTest
@testable import HouseholdClient

private final class LoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1", space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class NativeServiceWireTests: XCTestCase {
    func testNativeClientAgainstPostgres() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPort = env["RITC_WIRE_PORT"] else { throw XCTSkip("Run the PostgreSQL integration suite with RITC_TEST_NATIVE_WIRE=1.") }
        let port = try XCTUnwrap(UInt16(rawPort))
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)"))
        let certificate = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_CERT"])))
        let session = URLSession(configuration: .ephemeral, delegate: LoopbackTrust(certificate: certificate), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session: session)
        let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_native_fixture"),
                             vault: MemoryVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "wire@example.invalid", code: XCTUnwrap(env["RITC_WIRE_CODE"]))
        let householdID = try XCTUnwrap(env["RITC_WIRE_HOUSEHOLD"])
        let shop = try XCTUnwrap(env["RITC_WIRE_SHOP"])
        let vault = MemoryVault(), config = try ServiceConfiguration(baseURL: base)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport)
        _ = try await service.enroll(householdID: householdID)
        let scope = try await service.selectShop(XCTUnwrap(UUID(uuidString: shop)))
        XCTAssertEqual(scope.shopId, shop)
        if let earlierRequest = env["RITC_WIRE_DEFERRED_REQUEST"] {
            try await exerciseDeferredRequest(service, scope: scope, shopID: shop, earlierRequestID: earlierRequest)
            return
        }
        if let request = env["RITC_WIRE_PURCHASE_REQUEST"] {
            if env["RITC_WIRE_PURCHASE_READER"] == "1" {
                XCTAssertEqual(scope.role, "contributor")
                XCTAssertFalse(scope.capabilities.contains("request_purchase_confirmation"))
                let mine = try await service.ownRequests()
                XCTAssertEqual(mine.requests.map(\.id), [request])
                let own = try XCTUnwrap(mine.requests.first)
                XCTAssertEqual(own.originalItem, "Fictional cereal")
                XCTAssertEqual(own.purchaseOutcome, .notBought)
                XCTAssertEqual(own.status, "added")
                XCTAssertNil(own.linkedLineId)
                XCTAssertNil(own.authorAlias)
            } else {
                try await exercisePurchaseConfirmation(service, scope: scope, shopID: shop, requestID: request)
            }
            return
        }
        let other = try XCTUnwrap(env["RITC_WIRE_OTHER"])
        let mealPlan = try await service.mealPlan(shopID: XCTUnwrap(UUID(uuidString: shop)))
        XCTAssertTrue(mealPlan.shopper)
        let observation = try await service.priceObservation(observationID: XCTUnwrap(env["RITC_WIRE_OBSERVATION"]))
        XCTAssertEqual(observation.shopId, shop)
        XCTAssertEqual(observation.sourceLocale, "es-US")
        var entered = observation
        entered.id = UUID().uuidString.lowercased()
        entered.itemName = "  Maíz  "
        let intent = try await service.preparePriceObservation(entered)
        let firstReceipt = try await service.executePriceObservation(intent)
        let replay = try await service.executePriceObservation(intent)
        XCTAssertEqual(replay, firstReceipt)
        let saved = try await service.priceObservation(observationID: entered.id)
        XCTAssertEqual(saved, entered)

        let current = try await service.shopperShop(shopID: shop)
        var patch = try ShopperShopCandidate(quote: current.quote, lines: current.lines).commandBody()
        let meal = SharedMeal(title: "Sopa de maíz", day: "2026-11-05", kind: "dinner", portions: 4, protected: false)
        patch["mealEdit"] = try SharedMealEdit(occurrenceID: UUID(), meal: meal).commandValue()
        let window = try await service.replayWindow()
        let op = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shop, kind: "shop.patch",
            base: .init(shopRevision: current.shopRevision, authorityEpoch: current.authorityEpoch), body: patch), bootstrap: scope)
        let mealReceipt = try await service.executeSharedShop(op)
        let mealReplay = try await service.executeSharedShop(op)
        XCTAssertEqual(mealReceipt.operationId, mealReplay.operationId)
        let revisedPlan = try await service.mealPlan(shopID: XCTUnwrap(UUID(uuidString: shop)))
        XCTAssertEqual(revisedPlan.meals.map(\.meal), [meal])
        if env["RITC_WIRE_PAID"] == "1" {
            let history = try await service.priceObservations()
            XCTAssertTrue(history.observations.contains(entered))
            let date = ISO8601DateFormatter()
            let period = try HistoryBudgetPeriod(title: "Dos compras", startsAt: date.string(from: Date().addingTimeInterval(-86400)),
                endsAt: date.string(from: Date().addingTimeInterval(86400)), timeZoneId: "America/New_York",
                shopBudgetMinor: 50000, alreadyExcludedReserveMinor: 0, shopIds: [shop, other], reservations: [], reviewedCompleteAt: nil)
            let selectedSources = try await service.historyOwnedShops()
            XCTAssertEqual(selectedSources.shops.map(\.shopId), [shop])
            do {
                _ = try await service.prepareBudgetPeriod(period, baseRevision: 0)
                XCTFail("The selected shop must not authorize a second shop.")
            } catch ClientError.service(status: 404, code: "unavailable", correlationID: _, retryAfter: _) { }
            _ = try await service.selectShop(nil)
            let overviewSources = try await service.historyOwnedShops()
            XCTAssertTrue(Set([shop, other]).isSubset(of: Set(overviewSources.shops.map(\.shopId))))
            let pending = try await service.prepareBudgetPeriod(period, baseRevision: 0)
            let receipt = try await service.executeBudgetPeriod(pending)
            let retained = try await service.savedBudgetPeriod(periodID: receipt.periodId)
            XCTAssertEqual(retained.period, period)
        } else {
            do {
                _ = try await service.priceObservations()
                XCTFail("Free must keep saved observations without granting paid history.")
            } catch ClientError.service(status: 403, code: "membership_inactive", correlationID: _, retryAfter: _) { }
        }
        let shopUUID = try XCTUnwrap(UUID(uuidString: shop))
        _ = try await service.selectShop(shopUUID)
        let decision = FamilyDecisionInput(kind: .preference, dish: "Sopa de maíz", product: "Maíz",
            occasion: nil, decision: "Prefer the smaller pack this time", outcome: nil)
        let initial = try await service.prepareFamilyDecision(shopID: shopUUID, id: nil, action: .create(decision))
        let recorded = try await service.executeFamilyDecision(initial)
        let sameRecord = try await service.executeFamilyDecision(initial)
        XCTAssertEqual(recorded, sameRecord)
        XCTAssertNil(recorded.outcome)
        XCTAssertEqual(recorded.scope, .oneShop)
        let observed = try await service.prepareFamilyDecision(shopID: shopUUID, id: recorded.id,
            action: .observe(version: recorded.version, text: "Two packs came home."))
        let updated = try await service.executeFamilyDecision(observed)
        XCTAssertEqual(updated.version, 2)
        let promote = try await service.prepareFamilyDecision(shopID: shopUUID, id: recorded.id, action: .promote(version: updated.version))
        if env["RITC_WIRE_PAID"] == "1" {
            let page = try await service.familyDecisions(dish: "sopa", product: "Maíz", occasion: nil, cursor: nil)
            XCTAssertEqual(page.decisions, [updated])
            let lasting = try await service.executeFamilyDecision(promote)
            XCTAssertEqual(lasting.scope, .lasting)
            let replayed = try await service.executeFamilyDecision(promote)
            XCTAssertEqual(lasting, replayed)
        } else {
            do {
                _ = try await service.executeFamilyDecision(promote)
                XCTFail("A Free saved record must not grant a paid lasting preference.")
            } catch ClientError.service(status: 403, code: "membership_inactive", correlationID: _, retryAfter: _) { }
            let saved = try await service.familyDecision(shopID: shopUUID, id: recorded.id)
            XCTAssertEqual(saved, updated)
        }
        let second = try await service.selectShop(XCTUnwrap(UUID(uuidString: other)))
        XCTAssertEqual(second.shopId, other)
        let reopened = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport)
        let restored = try await reopened.enroll(householdID: householdID)
        XCTAssertEqual(restored.shopId, other)

        // Placement uses the actual Swift transport, pinned loopback TLS and PostgreSQL route.
        let originalPlacement = try await reopened.placementShop(shopID: other)
        let capture = try await reopened.preparePlacementSnapshot(reviewed: originalPlacement)
        XCTAssertEqual(capture.snapshot, originalPlacement)
        let clock = ISO8601DateFormatter(); clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let occurredAt = clock.string(from: Date())
        let sealedReport = try capture.report(occurredAt: occurredAt)
        let persistedReport = try JSONDecoder().decode(PlacementReportIntent.self, from: JSONEncoder().encode(sealedReport))
        XCTAssertEqual(persistedReport.bytes, sealedReport.bytes)
        let placementReceipt = try await reopened.executePlacementReport(persistedReport)
        let placementReplay = try await reopened.executePlacementReport(persistedReport)
        XCTAssertEqual(placementReplay, placementReceipt)
        XCTAssertEqual(placementReceipt.disposition, "placed")
        let receivedStatus = try await reopened.placementReportStatus(persistedReport)
        let placementStatus = try XCTUnwrap(receivedStatus)
        XCTAssertEqual(placementStatus.reportId, placementReceipt.reportId)
        XCTAssertEqual(placementStatus.state, "applied")
        XCTAssertEqual(placementStatus.occurredAt, occurredAt)
        XCTAssertEqual(placementStatus.reportedRevision, originalPlacement.shopRevision)
        XCTAssertEqual(placementStatus.reportedAuthorityEpoch, originalPlacement.authorityEpoch)
        let placedDetail = try await reopened.placementReport(shopID: other, reportID: placementReceipt.reportId)
        XCTAssertEqual(placedDetail.report.snapshot.quote, originalPlacement.quote)
        XCTAssertEqual(placedDetail.report.snapshot.lines, originalPlacement.lines)
        XCTAssertEqual(placedDetail.report.snapshot.revision, originalPlacement.shopRevision)
        XCTAssertEqual(placedDetail.report.occurredAt, occurredAt)
        let minimal = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(placementStatus)) as? [String: Any])
        XCTAssertEqual(Set(minimal.keys), ["clientKey", "operationId", "reportId", "shopId", "reportedRevision", "reportedAuthorityEpoch", "occurredAt", "receivedAt", "source", "state"])
    }

    private func exerciseDeferredRequest(_ service: HouseholdService, scope: HouseholdBootstrap, shopID: String,
                                         earlierRequestID: String) async throws {
        XCTAssertTrue(scope.capabilities.contains("deferred_requests"))
        let draft = try await service.shopperShop(shopID: shopID)
        let available = try await service.deferredRequests(shopID: shopID)
        XCTAssertEqual(available.requests.count, 1)
        let source = try XCTUnwrap(available.requests.first)
        XCTAssertEqual(source.id.uuidString.lowercased(), earlierRequestID)
        XCTAssertEqual(source.authorAlias, "Alex")
        let earlierShop = source.sourceShopId.uuidString.lowercased()
        _ = try await service.selectShop(source.sourceShopId)
        let placed = try await service.shopperShop(shopID: earlierShop)
        let oldLine = try XCTUnwrap(placed.lines.first { $0.originalItem == source.originalItem })
        XCTAssertEqual(oldLine.unitPriceMinor, 3720)
        XCTAssertEqual(placed.phase, "placed")
        _ = try await service.selectShop(UUID(uuidString: shopID))
        let before = try await service.shopperInbox(shopID: shopID)
        XCTAssertTrue(before.requests.isEmpty)
        XCTAssertTrue(draft.lines.isEmpty)
        let window = try await service.replayWindow()
        let base = CommandBase(shopRevision: available.shopRevision, authorityEpoch: available.authorityEpoch,
                               requestRevision: source.requestRevision)
        let op = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shopID, kind: "request.carry",
            base: base, body: ["requestId": .string(earlierRequestID), "sourceShopId": .string(earlierShop),
                               "sourceAuthorityEpoch": .integer(source.sourceAuthorityEpoch)]), bootstrap: scope)
        let receipt = try await service.executeShopper(op)
        let retried = try await service.executeShopper(op)
        XCTAssertEqual(receipt, retried)
        let successorID = try XCTUnwrap(receipt.requestId)
        XCTAssertEqual(receipt.operationId, successorID)
        let afterCarry = try await service.shopperShop(shopID: shopID)
        XCTAssertEqual(afterCarry, draft)
        let remaining = try await service.deferredRequests(shopID: shopID)
        XCTAssertTrue(remaining.requests.isEmpty)
        let inbox = try await service.shopperInbox(shopID: shopID)
        XCTAssertEqual(inbox.requests.map(\.id), [successorID])
        let successor = try XCTUnwrap(inbox.requests.first)
        XCTAssertEqual(successor.fromPreviousShop, true)
        XCTAssertEqual(successor.status, "pending")
        XCTAssertEqual(successor.originalItem, source.originalItem)
        XCTAssertEqual(successor.authorAlias, source.authorAlias)
        XCTAssertEqual(successor.ownQuantity, source.ownQuantity)

        let requestBase = CommandBase(shopRevision: draft.shopRevision, authorityEpoch: draft.authorityEpoch,
                                      requestRevision: successor.revision)
        let newLineID = UUID()
        func previewLine(_ price: Int?) async throws -> ShopperPreview {
            let line = ShopperBasketLine(lineId: newLineID, originalItem: successor.originalItem, packs: 1,
                                         unitPriceMinor: price, feeEligible: true)
            return try await service.shopperPreview(shopID: shopID, requestID: successorID, base: requestBase,
                                                    decision: .add(line: line, promote: false))
        }
        let unknown = try await previewLine(nil)
        XCTAssertTrue(unknown.requiresUnknownAcceptance)
        XCTAssertNil(unknown.after.totalMinor)
        let priced = try await previewLine(425)
        XCTAssertFalse(priced.requiresUnknownAcceptance)
        XCTAssertEqual(priced.after.totalMinor, 425)
        let apply = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shopID, kind: "request.apply",
            base: priced.base, body: ["requestId": .string(successorID), "previewId": .string(priced.previewId),
                                      "acceptOverage": .bool(false), "acceptUnknown": .bool(false)]), bootstrap: scope)
        let applied = try await service.executeShopper(apply)
        XCTAssertEqual(applied.disposition, "added")
        let lateRetry = try await service.executeShopper(op)
        XCTAssertEqual(lateRetry, receipt)
        let saved = try await service.shopperShop(shopID: shopID)
        XCTAssertEqual(saved.lines.map(\.unitPriceMinor), [425])
        XCTAssertEqual(saved.lines.map(\.originalItem), [source.originalItem])
        _ = try await service.selectShop(source.sourceShopId)
        let original = try await service.shopperShop(shopID: earlierShop)
        XCTAssertEqual(original, placed)
        let history = try await service.shopperInbox(shopID: earlierShop)
        XCTAssertEqual(history.requests.map(\.id), [earlierRequestID])
        XCTAssertEqual(history.requests.first?.carriedForward, true)
    }

    private func exercisePurchaseConfirmation(_ service: HouseholdService, scope: HouseholdBootstrap,
                                              shopID: String, requestID: String) async throws {
        XCTAssertTrue(scope.capabilities.contains("request_purchase_confirmation"))
        let shop = try await service.shopperShop(shopID: shopID)
        let placed = try await service.deliveryEvidence(shopID: shopID)
        let window = try await service.replayWindow()
        var expected: ConfirmedRequestPurchase?
        for outcome: ConfirmedRequestPurchase? in [.bought, nil, .notBought] {
            let page = try await service.shopperInbox(shopID: shopID)
            let request = try XCTUnwrap(page.requests.first { $0.id == requestID })
            let match = try XCTUnwrap(RequestPurchaseMatch(request: request, shop: shop, placed: placed))
            XCTAssertEqual(match.request.originalItem, "Fictional cereal")
            XCTAssertEqual(match.request.authorAlias, "Alex")
            XCTAssertEqual(match.request.ownQuantity, "one box")
            XCTAssertEqual(match.request.purchaseOutcome, expected)
            XCTAssertEqual(match.line.name, "Original basket")
            XCTAssertEqual(match.line.packs, 1)
            let op = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shopID,
                kind: "request.confirmPurchase", base: match.base, body: match.body(outcome: outcome)), bootstrap: scope)
            XCTAssertFalse(op.targetsShop(nil))
            XCTAssertFalse(op.targetsShop(UUID().uuidString))
            let first = try await service.executeShopper(op)
            let retry = try await service.executeShopper(op)
            XCTAssertEqual(first, retry)
            XCTAssertEqual(first.purchaseOutcome, outcome?.rawValue ?? "unknown")
            XCTAssertEqual(first.requestRevision, request.revision + 1)
            expected = outcome
        }
        let final = try await service.shopperInbox(shopID: shopID)
        let saved = try XCTUnwrap(final.requests.first { $0.id == requestID })
        XCTAssertEqual(saved.purchaseOutcome, .notBought)
        XCTAssertEqual(saved.status, "added")
        XCTAssertEqual(saved.linkedLineId, placed.lines.first?.id)
    }
}
