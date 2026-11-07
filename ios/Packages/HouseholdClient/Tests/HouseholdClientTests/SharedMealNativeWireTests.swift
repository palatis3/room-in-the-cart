import Security
import XCTest
@testable import HouseholdClient

private final class SharedMealLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
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

final class SharedMealNativeWireTests: XCTestCase {
    func testSharedMealClientAgainstPostgres() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPort = env["RITC_WIRE_PORT"] else { throw XCTSkip("Run isolated shared meal PostgreSQL tests with RITC_TEST_NATIVE_WIRE=1.") }
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(rawPort)"))
        let cert = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_CERT"])))
        let session = URLSession(configuration: .ephemeral, delegate: SharedMealLoopbackTrust(certificate: cert), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session: session)
        let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_meal_fixture"), vault: MemoryVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "wire@example.invalid", code: XCTUnwrap(env["RITC_WIRE_CODE"]))
        let service = HouseholdService(configuration: try .init(baseURL: base), auth: auth, deviceVault: MemoryVault(), transport: transport)
        _ = try await service.enroll(householdID: XCTUnwrap(env["RITC_WIRE_HOUSEHOLD"]))
        let shopID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(env["RITC_WIRE_SHOP"])))
        let scope = try await service.selectShop(shopID)
        let page = try await service.sharedMealChanges(shopID: shopID)
        if env["RITC_WIRE_SHOPPER"] == "1" {
            XCTAssertTrue(page.shopper)
            let proposal = try XCTUnwrap(page.proposals.first)
            XCTAssertTrue(proposal.isCurrent(in: page)); XCTAssertNotNil(proposal.request.meal.planning?.bindings)
            let current = try await service.shopperShop(shopID: shopID.uuidString.lowercased())
            var body = try ShopperShopCandidate(quote: current.quote, lines: current.lines).commandBody()
            var edit = SharedMealEdit(occurrenceID: proposal.request.occurrenceId, meal: proposal.request.meal, changeProposalID: proposal.id)
            edit.baseMealRevision = proposal.request.baseMealRevision
            body["mealEdit"] = try edit.commandValue()
            let window = try await service.replayWindow()
            let op = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: current.shopId, kind: "shop.patch", base: .init(shopRevision: current.shopRevision, authorityEpoch: current.authorityEpoch), body: body), bootstrap: scope)
            let first = try await service.executeSharedShop(op), retry = try await service.executeSharedShop(op)
            XCTAssertEqual(first.operationId, retry.operationId)
            let updated = try await service.sharedMealChanges(shopID: shopID)
            XCTAssertEqual(updated.proposals.first?.state, "applied")
            XCTAssertEqual(updated.meals.first?.meal, proposal.request.meal)
            let reviewedShop = try await service.shopperShop(shopID: current.shopId)
            XCTAssertEqual(reviewedShop.shopRevision, current.shopRevision + 1)
            let prepared = try await service.preparePlacementSnapshot(reviewed: reviewedShop)
            let placed = try await service.executePlacementReport(try .init(prepared: prepared, occurredAt: ISO8601DateFormatter().string(from: Date())))
            XCTAssertEqual(placed.disposition, "placed")
            try await exerciseDelivery(service, scope: scope, shopID: current.shopId)

        } else {
            XCTAssertFalse(page.shopper)
            let occurrence = try XCTUnwrap(page.meals.first)
            var meal = occurrence.meal
            meal.title = "Reviewed native guest plan"
            meal.planning?.exclusions = ["no peanuts"]
            meal.planning?.leadTimeMinutes = 120
            meal.planning?.completedSteps = ["Beans soaked"]
            let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: occurrence.id, meal: meal, reason: "Exact native proposal across two adults")
            try await service.executeSharedMealChange(intent)
            try await service.executeSharedMealChange(intent)
            let updated = try await service.sharedMealChanges(shopID: shopID)
            XCTAssertEqual(updated.proposals.count, 1); XCTAssertEqual(updated.proposals[0].request, intent.request)
            XCTAssertEqual(updated.meals, page.meals)
        }
    }
    private func exerciseDelivery(_ service: HouseholdService, scope: HouseholdBootstrap, shopID: String) async throws {
        func save(_ change: SharedDeliveryEdit, page: SharedDeliveryPage) async throws -> ShopperReceipt {
            let window = try await service.replayWindow()
            let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shopID, kind: change.kind,
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: change.body(reviewed: page)), bootstrap: scope)
            let first = try await service.executeSharedShop(operation)
            let replay = try await service.executeSharedShop(operation)
            XCTAssertEqual(replay, first)
            return first
        }
        let empty = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertTrue(empty.sources.isEmpty)
        let sealedPlan = try XCTUnwrap(empty.meals?.first(where: { $0.meal.title == "Reviewed native guest plan" })?.meal.planning)
        XCTAssertEqual(sealedPlan.exclusions, ["no peanuts"])
        XCTAssertEqual(sealedPlan.leadTimeMinutes, 120)
        XCTAssertEqual(sealedPlan.completedSteps, ["Beans soaked"])
        let sealed = try XCTUnwrap(empty.lines.first)
        let receipt = try await save(.register(lineID: sealed.id, segment: UUID(), name: "Cannellini beans", exclusions: []), page: empty)
        let source = try XCTUnwrap(receipt.sourceId)
        let registered = try await service.deliveryEvidence(shopID: shopID)
        let amount: (Int) -> SharedMealQuantity = { .init(amount: .init(numerator: $0), unit: "gram", originalLiteral: String($0)) }
        let arrival = UUID()
        _ = try await save(.arrival(source: source, previous: nil, observation: arrival, date: Date().addingTimeInterval(-90), received: amount(8)), page: registered)
        let arrived = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertNil(arrived.sources.first?.confirmed)
        let usable = UUID()
        _ = try await save(.usable(source: source, previous: nil, arrival: arrival, observation: usable, date: Date(), quantity: amount(6)), page: arrived)
        let counted = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(counted.sources.first?.confirmed?.quantity, amount(6))
        _ = try await save(.usable(source: source, previous: usable, arrival: arrival, observation: UUID(), date: Date(), quantity: amount(7)), page: counted)
        let corrected = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(corrected.lines, empty.lines)
        XCTAssertEqual(corrected.shopRevision, empty.shopRevision)
        XCTAssertEqual(corrected.supplyRevision, 4)
        XCTAssertEqual(corrected.sources.count, 1)
        XCTAssertEqual(corrected.sources.first?.confirmed?.quantity, amount(7))
        XCTAssertEqual(corrected.sources.first?.arrival?.received, amount(8))
        let occurrence = try XCTUnwrap(corrected.meals?.first)
        let ingredient = try XCTUnwrap(occurrence.meal.planning?.ingredients.first)
        let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
        XCTAssertEqual(occurrence.meal.title, "Reviewed native guest plan")
        XCTAssertEqual(ingredient.name, "Beans")
        XCTAssertEqual(corrected.sources.first?.matches, [])
        _ = try await save(.match(source: source, ingredient: target, matched: true), page: corrected)
        let matched = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(matched.sources.first?.matches, [target])
        XCTAssertEqual(matched.sources.first?.confirmed, corrected.sources.first?.confirmed)
        let coverage = try await service.deliveryCoverage(reviewed: matched)
        let lunch = try XCTUnwrap(coverage.needs.first(where: { $0.protected }))
        let dinner = try XCTUnwrap(coverage.needs.first(where: { !$0.protected }))
        XCTAssertEqual(lunch.covered?.formatted, "7"); XCTAssertEqual(lunch.missing?.formatted, "193")
        XCTAssertEqual(lunch.allocations.map(\.sourceId), [source])
        XCTAssertEqual(dinner.covered?.formatted, "0")
        XCTAssertEqual(matched.reservationsAvailable, true)
        let group = try XCTUnwrap(lunch.groupIds.first)
        let claim = try await save(.reserve(source: source, ingredient: target, group: group, previous: nil, quantity: amount(4)), page: matched)
        let reserved = try await service.deliveryEvidence(shopID: shopID)
        let head = try XCTUnwrap(reserved.sources.first?.reservations?.first)
        XCTAssertEqual(head.reservationId, UUID(uuidString: claim.operationId))
        XCTAssertEqual(head.quantity, amount(4))
        XCTAssertThrowsError(try SharedDeliveryEdit.match(source: source, ingredient: target, matched: false).body(reviewed: reserved))
        let reservedCoverage = try await service.deliveryCoverage(reviewed: reserved)
        let backed = try XCTUnwrap(reservedCoverage.needs.first(where: { $0.groupIds == [group] })?.reservations?.first)
        XCTAssertEqual(backed.reservationId, head.reservationId)
        XCTAssertEqual(backed.requested.formatted, "4")
        XCTAssertEqual(backed.backed.formatted, "4")

        let reviewedText = "Almuerzo · 4 g reservados\nMantener aparte del cacahuate.  "
        let initialCookCopy = try await writeCookCopy(.save(text: reviewedText, language: "es", occurrence: occurrence),
                                                      service: service, scope: scope, page: reserved)
        let saved = try await service.cookCopies(occurrence: occurrence, reviewed: reserved)
        let original = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(original.copyId, initialCookCopy.copyId)
        XCTAssertEqual(original.version, 1)
        XCTAssertEqual(original.supplyRevision, reserved.supplyRevision)
        XCTAssertEqual(Array(original.text.utf8), Array(reviewedText.utf8))
        let unsent = try await service.cookCopyBaseline(recipient: "Ana", occurrence: occurrence, reviewed: reserved)
        XCTAssertNil(unsent)

        let earlierCount = try XCTUnwrap(reserved.sources.first?.usable?.observationId)
        let correction = UUID()
        _ = try await save(.usable(source: source, previous: earlierCount, arrival: arrival, observation: correction,
                                   date: Date(), quantity: amount(2)), page: reserved)
        let short = try await service.deliveryEvidence(shopID: shopID)
        let shortCoverage = try await service.deliveryCoverage(reviewed: short)
        let shortRow = try XCTUnwrap(shortCoverage.needs.first(where: { $0.groupIds == [group] }))
        XCTAssertEqual(shortRow.reservations?.first?.requested.formatted, "4")
        XCTAssertEqual(shortRow.reservations?.first?.backed.formatted, "2")
        XCTAssertTrue(shortRow.issues.contains("reservationShortfall"))
        let updatedCookCopy = try await writeCookCopy(.save(text: "Only 2 g backed.", language: "en", occurrence: occurrence),
                                                      service: service, scope: scope, page: short)
        let versions = try await service.cookCopies(occurrence: occurrence, reviewed: short)
        XCTAssertEqual(versions.map(\.version), [2, 1])
        XCTAssertEqual(versions.first?.id, updatedCookCopy.copyId)
        XCTAssertEqual(versions.last, original)
        let sent = try await writeCookCopy(.markSent(copy: original, recipient: "Ana", previousSendId: nil),
                                           service: service, scope: scope, page: short)
        let baseline = try await service.cookCopyBaseline(recipient: "Ana", occurrence: occurrence, reviewed: short)
        XCTAssertEqual(baseline?.copy, original)
        XCTAssertEqual(baseline?.send.sendId, UUID(uuidString: sent.operationId))
        let otherCook = try await service.cookCopyBaseline(recipient: "Luis", occurrence: occurrence, reviewed: short)
        XCTAssertNil(otherCook)
        let unknown = UUID()
        _ = try await save(.usable(source: source, previous: correction, arrival: arrival, observation: unknown,
                                   date: Date(), quantity: nil), page: short)
        let unconfirmed = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertNil(unconfirmed.sources.first?.confirmed)
        let reduction = try await save(.reserve(source: source, ingredient: target, group: group, previous: head.reservationId,
                                               quantity: amount(3)), page: unconfirmed)
        let reduced = try await service.deliveryEvidence(shopID: shopID)
        let reducedHead = try XCTUnwrap(reduced.sources.first?.reservations?.first)
        XCTAssertEqual(reducedHead.reservationId, UUID(uuidString: reduction.operationId))
        let reducedCoverage = try await service.deliveryCoverage(reviewed: reduced)
        let reducedClaim = try XCTUnwrap(reducedCoverage.needs.first(where: { $0.groupIds == [group] })?.reservations?.first)
        XCTAssertEqual(reducedClaim.requested.formatted, "3")
        XCTAssertEqual(reducedClaim.backed.formatted, "0")
        let release = try await save(.reserve(source: source, ingredient: target, group: group, previous: reducedHead.reservationId, quantity: nil), page: reduced)
        let released = try await service.deliveryEvidence(shopID: shopID)
        let releasedHead = try XCTUnwrap(released.sources.first?.reservations?.first)
        XCTAssertNil(releasedHead.quantity)
        XCTAssertEqual(releasedHead.reservationId, UUID(uuidString: release.operationId))
        let releasedCoverage = try await service.deliveryCoverage(reviewed: released)
        XCTAssertTrue(releasedCoverage.needs.allSatisfy { $0.reservations?.isEmpty == true })
        _ = try await save(.usable(source: source, previous: unknown, arrival: arrival, observation: UUID(),
                                   date: Date(), quantity: amount(7)), page: released)
        let restored = try await service.deliveryEvidence(shopID: shopID)
        _ = try await save(.match(source: source, ingredient: target, matched: false), page: restored)
        let removed = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(removed.sources.first?.matches, [])
        XCTAssertEqual(removed.supplyRevision, restored.supplyRevision + 1)
        XCTAssertEqual(removed.sources.first?.reservations?.first, releasedHead)
        let unlinked = try await service.deliveryCoverage(reviewed: removed)
        XCTAssertTrue(unlinked.needs.allSatisfy { $0.covered?.formatted == "0" && $0.issues.contains("noMatch") })
        do { _ = try await service.deliveryCoverage(reviewed: matched); XCTFail("Displayed stale counts after removing match") }
        catch { XCTAssertEqual(error as? ClientError, .service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)) }
    }
    private func writeCookCopy(_ change: SharedCookCopyEdit, service: HouseholdService, scope: HouseholdBootstrap,
                               page: SharedDeliveryPage) async throws -> ShopperReceipt {
        let window = try await service.replayWindow()
        let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: page.shopId.uuidString.lowercased(),
            kind: change.kind, base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch),
            body: change.body(reviewed: page)), bootstrap: scope)
        let first = try await service.executeSharedShop(operation)
        let replay = try await service.executeSharedShop(operation)
        XCTAssertEqual(replay, first)
        return first
    }

}
