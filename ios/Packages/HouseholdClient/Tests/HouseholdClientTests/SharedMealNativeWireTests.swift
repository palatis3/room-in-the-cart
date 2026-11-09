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
    private let deadline = SharedMealDeadline(at: "2099-11-01T06:30:00Z", zone: "America/New_York")

    func testSharedMealClientAgainstPostgres() async throws {
        let env = ProcessInfo.processInfo.environment
        if env["RITC_WIRE_DEMAND_PHASE"] != nil { try await exerciseSharedDemandWire(); return }
        if env["RITC_WIRE_REMOVAL_PHASE"] != nil {
            try await exerciseSourceRemovalAcrossClients()
            return
        }
        if env["RITC_WIRE_UNDATED_PHASE"] != nil {
            try await exerciseUnscheduledSelectionAcrossRestart()
            return
        }
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
        if env["RITC_WIRE_FALLBACK"] == "1" {
            try await exerciseFallback(service, shop: shopID, scope: scope)
            return
        }
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
            let occurrence = try XCTUnwrap(reviewedShop.meals?.first)
            XCTAssertEqual(occurrence.meal.day, "2099-11-01")
            XCTAssertNil(occurrence.meal.planning?.deadline)
            var meal = occurrence.meal
            try meal.setDeadline(deadline)
            var timedEdit = SharedMealEdit(occurrenceID: occurrence.id, meal: meal)
            timedEdit.baseMealRevision = occurrence.revision
            var timedBody = try ShopperShopCandidate(quote: reviewedShop.quote, lines: reviewedShop.lines).commandBody()
            timedBody["mealEdit"] = try timedEdit.commandValue()
            let timedOperation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: current.shopId,
                kind: "shop.patch", base: .init(shopRevision: reviewedShop.shopRevision, authorityEpoch: reviewedShop.authorityEpoch),
                body: timedBody), bootstrap: scope)
            _ = try await service.executeSharedShop(timedOperation)
            let timedShop = try await service.shopperShop(shopID: current.shopId)
            XCTAssertEqual(timedShop.meals?.first?.meal.planning?.deadline, deadline)
            let prepared = try await service.preparePlacementSnapshot(reviewed: timedShop)
            let placed = try await service.executePlacementReport(try .init(prepared: prepared, occurredAt: ISO8601DateFormatter().string(from: Date())))
            XCTAssertEqual(placed.disposition, "placed")
            try await exerciseDelivery(service, scope: scope, shopID: current.shopId)
            try await exerciseConfirmedAmendment(service, shopID: shopID)

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

    private struct RemovalExpectation: Decodable {
        let target: UUID
        let revision: Int
        let meals: [SharedMealOccurrence]
        let lines: [ShopperBasketLine]
        let quote: ShopperQuote
    }

    /// Real public routes, with independently seeded identities. Cancel means a
    /// prepared client operation is discarded; this does not simulate a UI tap.
    private func exerciseSourceRemovalAcrossClients() async throws {
        let env = ProcessInfo.processInfo.environment
        let phase = try XCTUnwrap(env["RITC_WIRE_REMOVAL_PHASE"])
        guard ["cancel", "remove", "read"].contains(phase) else { return XCTFail("Unknown removal phase") }
        let expected = try JSONDecoder().decode(RemovalExpectation.self, from: Data(XCTUnwrap(env["RITC_WIRE_REMOVAL_EXPECTED"]).utf8))
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(try XCTUnwrap(env["RITC_WIRE_PORT"]))"))
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
        let survivors = expected.meals.filter { $0.id != expected.target }
        func assertMeals(_ actual: [SharedMealOccurrence], _ wanted: [SharedMealOccurrence]) {
            XCTAssertEqual(actual.count, wanted.count)
            for meal in wanted { XCTAssertEqual(actual.first(where: { $0.id == meal.id }), meal) }
            XCTAssertEqual(Set(actual.map(\.id)), Set(wanted.map(\.id)))
        }
        if phase == "read" {
            let page = try await service.sharedMealChanges(shopID: shopID)
            XCTAssertFalse(page.shopper)
            XCTAssertEqual(page.shopRevision, expected.revision + 1)
            assertMeals(page.meals, survivors)
            XCTAssertFalse(page.meals.contains(where: { $0.id == expected.target }))
            return
        }
        let current = try await service.shopperShop(shopID: shopID.uuidString.lowercased())
        XCTAssertEqual(current.shopRevision, expected.revision)
        assertMeals(current.meals ?? [], expected.meals)
        XCTAssertEqual(current.lines, expected.lines); XCTAssertEqual(current.quote, expected.quote)
        let removed = try XCTUnwrap(expected.meals.first(where: { $0.id == expected.target }))
        var edit = SharedMealEdit(occurrenceID: expected.target, meal: nil)
        edit.baseMealRevision = removed.revision
        var body = try ShopperShopCandidate(quote: current.quote, lines: current.lines).commandBody()
        body["mealEdit"] = try edit.commandValue()
        let window = try await service.replayWindow()
        let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: current.shopId,
            kind: "shop.patch", base: .init(shopRevision: current.shopRevision, authorityEpoch: current.authorityEpoch), body: body), bootstrap: scope)
        if phase == "cancel" {
            // No execute call: parent independently asserts zero /commands and
            // byte-equivalent authoritative history, snapshots and current facts.
            let unchanged = try await service.shopperShop(shopID: current.shopId)
            XCTAssertEqual(unchanged, current)
            return
        }
        let restored = try JSONDecoder().decode(PendingOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertEqual(restored.bytes, operation.bytes); XCTAssertEqual(restored, operation)
        let first = try await service.executeSharedShop(operation)
        let retry = try await service.executeSharedShop(restored)
        XCTAssertEqual(first, retry); XCTAssertEqual(first.shopRevision, expected.revision + 1)
        let final = try await service.shopperShop(shopID: current.shopId)
        XCTAssertEqual(final.shopRevision, expected.revision + 1)
        XCTAssertEqual(final.lines, expected.lines); XCTAssertEqual(final.quote, expected.quote)
        assertMeals(final.meals ?? [], survivors)
    }

    /// Two separate Swift processes share only the real PostgreSQL shop and fixture IDs.
    private func exerciseUnscheduledSelectionAcrossRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        let phase = try XCTUnwrap(env["RITC_WIRE_UNDATED_PHASE"])
        XCTAssertTrue(["select", "schedule"].contains(phase))
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(try XCTUnwrap(env["RITC_WIRE_PORT"]))"))
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
        let ids = try JSONDecoder().decode([String: UUID].self, from: Data(XCTUnwrap(env["RITC_WIRE_UNDATED_IDS"]).utf8))
        let occurrence = try XCTUnwrap(ids["occurrence"]), dinner = try XCTUnwrap(ids["dinner"])
        let lunch = try XCTUnwrap(ids["lunch"]), ingredient = try XCTUnwrap(ids["ingredient"])
        func quantity(_ n: Int) -> SharedMealQuantity { .init(amount: .init(numerator: n), unit: "count", originalLiteral: "\(n) wraps") }
        let planning = SharedMealPlanning(groups: [
            .init(id: dinner, name: "Dinner", servings: .init(numerator: 4), protected: false),
            .init(id: lunch, name: "Lunch", servings: .init(numerator: 2), protected: true)],
            ingredients: [.init(id: ingredient, name: "Wraps", quantity: quantity(6), groupIds: [dinner,lunch], exclusions: ["no peanuts"])],
            bindings: [.init(id: try XCTUnwrap(ids["dinnerAllocation"]), groupId: dinner, ingredientId: ingredient, quantity: quantity(4)),
                       .init(id: try XCTUnwrap(ids["lunchAllocation"]), groupId: lunch, ingredientId: ingredient, quantity: quantity(2))])
        var expected = SharedMeal(title: "Undated native supper", day: nil, kind: "dinner", portions: 6, protected: false, planning: planning)
        let current = try await service.shopperShop(shopID: shopID.uuidString.lowercased())
        let existing = current.meals ?? []
        let baseMealRevision: Int?
        if phase == "select" {
            XCTAssertEqual(current.shopRevision, 1); XCTAssertTrue(existing.isEmpty)
            baseMealRevision = nil
        } else {
            // This process has fresh auth, transport, device vault and service actors.
            // Its expected IDs come from the parent, never from the just-read meal.
            XCTAssertEqual(current.shopRevision, 2); XCTAssertEqual(existing.count, 1)
            let saved = try XCTUnwrap(existing.first)
            XCTAssertEqual(saved.id, occurrence); XCTAssertEqual(saved.revision, 2)
            XCTAssertEqual(saved.meal, expected)
            var moved = saved.meal; moved.move(to: "2099-11-01")
            XCTAssertEqual(moved.planning, planning); XCTAssertNil(moved.planning?.deadline)
            expected = moved; baseMealRevision = saved.revision
        }
        var edit = SharedMealEdit(occurrenceID: occurrence, meal: expected)
        edit.baseMealRevision = baseMealRevision
        var body = try ShopperShopCandidate(quote: current.quote, lines: current.lines).commandBody()
        body["mealEdit"] = try edit.commandValue()
        let window = try await service.replayWindow()
        let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: current.shopId,
            kind: "shop.patch", base: .init(shopRevision: current.shopRevision, authorityEpoch: current.authorityEpoch), body: body), bootstrap: scope)
        let restored = try JSONDecoder().decode(PendingOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertEqual(restored, operation); XCTAssertEqual(restored.bytes, operation.bytes)
        let first = try await service.executeSharedShop(operation)
        let retry = try await service.executeSharedShop(restored)
        XCTAssertEqual(first, retry); XCTAssertEqual(first.shopRevision, current.shopRevision + 1)
        let final = try await service.shopperShop(shopID: current.shopId)
        XCTAssertEqual(final.shopRevision, current.shopRevision + 1)
        XCTAssertEqual(final.lines, current.lines); XCTAssertEqual(final.quote, current.quote)
        XCTAssertEqual(final.meals?.count, 1)
        let saved = try XCTUnwrap(final.meals?.first)
        XCTAssertEqual(saved.id, occurrence); XCTAssertEqual(saved.revision, final.shopRevision)
        XCTAssertEqual(saved.meal, expected); XCTAssertEqual(saved.meal.planning, planning)
        XCTAssertNil(saved.meal.planning?.deadline)
    }

    private func exerciseConfirmedAmendment(_ service: HouseholdService, shopID: UUID) async throws {
        let id = shopID.uuidString.lowercased(), page = try await service.confirmedOrder(shopID: shopID)
        let original = try await service.shopperShop(shopID: id)
        let physical = try await service.deliveryEvidence(shopID: id)
        let financial = try await service.shopperFinancialRecord(shopID: id)
        let added = ShopperBasketLine(originalItem: "Independently confirmed replacement", packs: 3, unitPriceMinor: nil, feeEligible: false)
        func record(_ lines: [ShopperBasketLine], page: SharedConfirmedOrder) async throws -> ShopperReceipt {
            let confirmation = SharedOrderConfirmation(reference: "Native retailer ABC-51", confirmedAt: Date(), lines: lines)
            let window = try await service.replayWindow(), scope = try await service.bootstrap()
            let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: id, kind: "amendment.recordResponse",
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: confirmation.body(reviewed: page)), bootstrap: scope)
            let receipt = try await service.executeSharedShop(operation), retry = try await service.executeSharedShop(operation)
            XCTAssertEqual(receipt, retry)
            return receipt
        }
        let first = try await record([added], page: page)
        let changed = try await service.confirmedOrder(shopID: shopID)
        XCTAssertEqual(changed.original, page.original); XCTAssertEqual(changed.current.lines, [added])
        XCTAssertEqual(changed.amendments.count, 1); XCTAssertEqual(changed.current.amendmentId, first.amendmentId)
        let unchanged = try await service.shopperShop(shopID: id)
        XCTAssertEqual(unchanged.lines, original.lines); XCTAssertEqual(unchanged.quote, original.quote)
        XCTAssertEqual(unchanged.meals, original.meals); XCTAssertEqual(unchanged.placedRevision, original.placedRevision)
        let beforeArrival = try await service.deliveryEvidence(shopID: id)
        XCTAssertEqual(beforeArrival.sources, physical.sources); XCTAssertEqual(beforeArrival.supplyRevision, physical.supplyRevision)
        XCTAssertEqual(beforeArrival.lines.first(where: { $0.id == UUID(uuidString: added.lineId) })?.currentOrderedPacks, 3)
        XCTAssertTrue(beforeArrival.lines.filter { line in page.original.lines.contains { UUID(uuidString: $0.lineId) == line.id } }.allSatisfy { $0.currentOrderedPacks == 0 })
        let registration = SharedDeliveryEdit.register(lineID: try XCTUnwrap(UUID(uuidString: added.lineId)), segment: UUID(), name: added.originalItem, exclusions: [])
        let window = try await service.replayWindow(), scope = try await service.bootstrap()
        let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: id, kind: registration.kind,
            base: .init(shopRevision: beforeArrival.shopRevision, authorityEpoch: beforeArrival.authorityEpoch), body: registration.body(reviewed: beforeArrival)), bootstrap: scope)
        _ = try await service.executeSharedShop(operation)
        let registered = try await service.deliveryEvidence(shopID: id)
        XCTAssertNil(registered.sources.first(where: { $0.lineId == UUID(uuidString: added.lineId) })?.arrival)
        XCTAssertNil(registered.sources.first(where: { $0.lineId == UUID(uuidString: added.lineId) })?.confirmed)
        let beforeCancellation = try await service.confirmedOrder(shopID: shopID)
        _ = try await record([], page: beforeCancellation)
        let cancelled = try await service.confirmedOrder(shopID: shopID), retained = try await service.deliveryEvidence(shopID: id)
        XCTAssertTrue(cancelled.current.lines.isEmpty); XCTAssertEqual(cancelled.amendments.count, 2)
        XCTAssertEqual(retained.sources, registered.sources); XCTAssertEqual(retained.supplyRevision, registered.supplyRevision)
        let finalFinancial = try await service.shopperFinancialRecord(shopID: id)
        XCTAssertEqual(finalFinancial.entries, financial.entries)

        // Closing the app review does not claim that every physical bag arrived.
        let charge = ShopperFinancialEntry(kind: .postedCharge, amountMinor: 3720, occurredAt: Date().ISO8601Format(), sourceText: "Native closed pickup receipt")
        try await service.executeFinancial(service.prepareFinancial(.append(charge), reviewed: finalFinancial))
        let charged = try await service.shopperFinancialRecord(shopID: id)
        let pendingCredit = ShopperFinancialEntry(kind: .pendingCredit, amountMinor: 240, occurredAt: Date().ISO8601Format(),
            sourceText: "Native refund still pending", creditId: UUID(), chargeEvidenceKey: charge.evidenceKey)
        try await service.executeFinancial(service.prepareFinancial(.append(pendingCredit), reviewed: charged))
        let beforeClose = try await service.shopperFinancialRecord(shopID: id)
        let close = try await service.prepareFinancial(.close, reviewed: beforeClose)
        try await service.executeFinancial(close)
        try await service.executeFinancial(close)
        let closedShop = try await service.shopperShop(shopID: id)
        let closedOrder = try await service.confirmedOrder(shopID: shopID)
        let closedFinancial = try await service.shopperFinancialRecord(shopID: id)
        let closedPhysical = try await service.deliveryEvidence(shopID: id)
        XCTAssertEqual(closedShop.phase, "closed")
        XCTAssertEqual(closedShop.placedRevision, original.placedRevision)
        XCTAssertEqual(closedFinancial.entries, beforeClose.entries)
        XCTAssertEqual(closedPhysical.sources, retained.sources)
        let lateSource = try XCTUnwrap(closedPhysical.sources.first(where: { $0.lineId == UUID(uuidString: added.lineId) }))
        func saveClosed(_ edit: SharedDeliveryEdit, page: SharedDeliveryPage) async throws -> PendingOperation {
            let window = try await service.replayWindow(), scope = try await service.bootstrap()
            let command = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: id, kind: edit.kind,
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: edit.body(reviewed: page)), bootstrap: scope)
            let receipt = try await service.executeSharedShop(command), retry = try await service.executeSharedShop(command)
            XCTAssertEqual(receipt, retry); XCTAssertEqual(receipt.supplyRevision, page.supplyRevision + 1)
            return command
        }
        func amount(_ n: Int) -> SharedMealQuantity { .init(amount: .init(numerator: n), unit: "count", originalLiteral: String(n)) }
        let arrivalID = UUID(), usableID = UUID()
        let lateArrival = try await saveClosed(.arrival(source: lateSource.id, previous: nil, observation: arrivalID,
            date: Date(), received: amount(2)), page: closedPhysical)
        let arrived = try await service.deliveryEvidence(shopID: id)
        XCTAssertNil(arrived.sources.first(where: { $0.id == lateSource.id })?.confirmed)
        _ = try await saveClosed(.usable(source: lateSource.id, previous: nil, arrival: arrivalID, observation: usableID,
            date: Date(), quantity: amount(2)), page: arrived)
        let usable = try await service.deliveryEvidence(shopID: id)
        _ = try await saveClosed(.usable(source: lateSource.id, previous: usableID, arrival: arrivalID, observation: UUID(),
            date: Date(), quantity: amount(1)), page: usable)
        let corrected = try await service.deliveryEvidence(shopID: id)
        XCTAssertEqual(corrected.sources.count, retained.sources.count)
        XCTAssertEqual(corrected.supplyRevision, retained.supplyRevision + 3)
        XCTAssertEqual(corrected.sources.first(where: { $0.id == lateSource.id })?.confirmed?.quantity, amount(1))
        XCTAssertEqual(corrected.sources.filter { $0.id != lateSource.id }, retained.sources.filter { $0.id != lateSource.id })
        _ = try await service.executeSharedShop(lateArrival)
        let afterRetry = try await service.deliveryEvidence(shopID: id)
        XCTAssertEqual(afterRetry, corrected)
        let finalShop = try await service.shopperShop(shopID: id)
        let finalOrder = try await service.confirmedOrder(shopID: shopID)
        let unchangedFinancial = try await service.shopperFinancialRecord(shopID: id)
        XCTAssertEqual(finalShop, closedShop)
        XCTAssertEqual(finalOrder.original, closedOrder.original); XCTAssertEqual(finalOrder.current, closedOrder.current)
        XCTAssertEqual(finalOrder.amendments, closedOrder.amendments); XCTAssertEqual(finalOrder.shopRevision, closedOrder.shopRevision)
        XCTAssertEqual(unchangedFinancial, closedFinancial)
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
        XCTAssertEqual(sealedPlan.deadline, deadline)
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
        // Project the actual protected claim twice across a physical usable-count
        // change and carry the reviewed UTF-8 sections through the Swift HTTP client.
        func indexedCopy(_ page: SharedDeliveryPage) async throws -> (SharedCookCopy, SharedCookFactIndex) {
            let report = try await service.deliveryCoverage(reviewed: page)
            let need = try XCTUnwrap(report.needs.first(where: { $0.groupIds == [group] }))
            let claim = try XCTUnwrap(need.reservations?.first)
            let heading = occurrence.meal.title
            let portion = "\(ingredient.name) · apartado \(claim.requested.formatted) g · cubierto \(claim.backed.formatted) g"
            let sourceScope = "Entregas confirmadas", stamp = report.asOf
            let text = [heading, portion, sourceScope + "\n" + stamp].joined(separator: "\n\n")
            let index = try XCTUnwrap(SharedCookFactIndex(source: .delivery, sections: [
                .init(key: "meal", bytes: heading.utf8.count, unresolved: false),
                .init(key: "need." + ingredient.id.uuidString.lowercased(), bytes: portion.utf8.count, unresolved: !need.issues.isEmpty),
                .init(key: "scope", bytes: sourceScope.utf8.count, unresolved: false), .init(key: "stamp", bytes: stamp.utf8.count, unresolved: false)]))
            let receipt = try await writeCookCopy(.save(text: text, language: "es", occurrence: occurrence, facts: index),
                service: service, scope: scope, page: page)
            let copies = try await service.cookCopies(occurrence: occurrence, reviewed: page)
            let saved = try XCTUnwrap(copies.first)
            XCTAssertEqual(saved.copyId, receipt.copyId)
            XCTAssertEqual(saved.text, text)
            return (saved, index)
        }
        let (backedCopy, backedIndex) = try await indexedCopy(short)
        _ = try await writeCookCopy(.markSent(copy: backedCopy, recipient: "Sol", previousSendId: nil), service: service, scope: scope, page: short)
        let priorSend = try await service.cookCopyBaseline(recipient: "Sol", occurrence: occurrence, reviewed: short)
        let prior = try XCTUnwrap(priorSend)
        XCTAssertEqual(prior.copy, backedCopy)
        let unknown = UUID()
        _ = try await save(.usable(source: source, previous: correction, arrival: arrival, observation: unknown,
                                   date: Date(), quantity: nil), page: short)
        let unconfirmed = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertNil(unconfirmed.sources.first?.confirmed)
        let (unknownCopy, unknownIndex) = try await indexedCopy(unconfirmed)
        let review = try await service.cookCorrection(copy: unknownCopy, baseline: prior, recipient: "Sol", destinationConfirmed: true,
                                                      occurrence: occurrence, reviewed: unconfirmed)
        XCTAssertEqual(review.previousFacts, backedIndex)
        XCTAssertEqual(review.currentFacts, unknownIndex)
        let oldNeed = try XCTUnwrap(review.previousFacts?.pieces(in: backedCopy.text)?.first(where: { $0.section.key.hasPrefix("need.") }))
        let newNeed = try XCTUnwrap(review.currentFacts?.pieces(in: unknownCopy.text)?.first(where: { $0.section.key == oldNeed.section.key }))
        XCTAssertTrue(oldNeed.wording.hasSuffix("cubierto 2 g"))
        XCTAssertTrue(newNeed.wording.hasSuffix("cubierto 0 g"))
        XCTAssertTrue(newNeed.section.unresolved)
        let unchangedBaseline = try await service.cookCopyBaseline(recipient: "Sol", occurrence: occurrence, reviewed: unconfirmed)
        XCTAssertEqual(unchangedBaseline, prior)
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
        try await exercisePantry(service, scope: scope, delivery: removed, source: source, target: target, group: group)
    }

    private func exercisePantry(_ service: HouseholdService, scope: HouseholdBootstrap, delivery: SharedDeliveryPage, source: UUID,
                                target: SharedDeliveryPage.IngredientMatch, group: UUID) async throws {
        var pantry = try await service.pantryLots(reviewed: delivery)
        XCTAssertTrue(pantry.lots.isEmpty)
        func amount(_ n: Int) -> SharedMealQuantity { .init(amount: .init(numerator: n), unit: "gram", originalLiteral: String(n)) }
        func operation(_ kind: String, fields: [String: JSONValue]) async throws -> PendingOperation {
            let window = try await service.replayWindow()
            return try await service.prepare(envelope: .init(replayWindow: window.id, shopId: delivery.shopId.uuidString.lowercased(),
                kind: kind, base: .init(shopRevision: delivery.shopRevision, authorityEpoch: delivery.authorityEpoch), body: fields), bootstrap: scope)
        }
        func save(_ edit: SharedPantryEdit, preview: SharedPantryObservationPreview? = nil) async throws -> ShopperReceipt {
            var fields = try edit.body(reviewed: pantry, delivery: delivery)
            if let preview { fields["previewDigest"] = .string(preview.previewDigest) }
            let command = try await operation(edit.kind, fields: fields)
            let first = try await service.executeSharedShop(command)
            let again = try await service.executeSharedShop(command)
            XCTAssertEqual(first, again)
            pantry = try await service.pantryLots(reviewed: delivery)
            XCTAssertEqual(pantry.pantryRevision, first.pantryRevision)
            return first
        }
        let created = try await save(.create(location: "freezer", storedAt: nil, useFirstAt: nil, name: "Beans", exclusions: []))
        let lot = try XCTUnwrap(created.lotId)
        XCTAssertNil(pantry.lots.first?.storedAt)
        XCTAssertNil(pantry.lots.first?.observation)
        XCTAssertEqual(pantry.lots.first?.selected, false)
        let observation = SharedPantryEdit.observe(lot: lot, previous: nil, confirmedAt: Date(), quantity: amount(5))
        let preview = try await service.previewPantryObservation(observation, reviewed: pantry, delivery: delivery)
        XCTAssertTrue(preview.needs.isEmpty)
        let head = try await save(observation, preview: preview)
        _ = try await save(.select(lot: lot, selected: true))
        _ = try await save(.match(lot: lot, ingredient: target, matched: true))
        _ = try await save(.reserve(lot: lot, ingredient: target, group: group, previous: nil, quantity: amount(4)))
        let full = try await service.foodCoverage(reviewed: pantry, delivery: delivery)
        let lunch = try XCTUnwrap(full.needs.first(where: { $0.groupIds == [group] }))
        XCTAssertEqual(lunch.freezer?.formatted, "5")
        XCTAssertEqual(lunch.delivered?.formatted, "0")
        XCTAssertEqual(lunch.reservations?.first?.backed.formatted, "4")
        let corrected = SharedPantryEdit.observe(lot: lot, previous: UUID(uuidString: head.operationId), confirmedAt: Date(), quantity: amount(2))
        let impact = try await service.previewPantryObservation(corrected, reviewed: pantry, delivery: delivery)
        let changedLunch = try XCTUnwrap(impact.needs.first(where: { $0.groupIds == [group] }))
        XCTAssertEqual(changedLunch.beforeCovered?.formatted, "5")
        XCTAssertEqual(changedLunch.afterCovered?.formatted, "2")
        let occurrence = try XCTUnwrap(delivery.meals?.first(where: { $0.id == target.occurrenceId }))
        let cook = SharedCookCopyEdit.save(text: "Keep five grams apart", language: "en", occurrence: occurrence)
        let cookFields = try cook.body(reviewed: delivery, pantry: pantry)
        let original = try await operation(cook.kind, fields: cookFields)
        let first = try await service.executeSharedShop(original)
        let saved = try await service.cookCopies(occurrence: occurrence, reviewed: delivery)
        XCTAssertEqual(saved.first?.copyId, first.copyId)
        XCTAssertEqual(saved.first?.pantryRevision, pantry.pantryRevision)
        _ = try await save(corrected, preview: impact)
        let stale = try await operation(cook.kind, fields: cookFields)
        do { _ = try await service.executeSharedShop(stale); XCTFail("Saved a stale pantry-based cook copy") }
        catch ClientError.service(status: 409, code: "stale_supply", correlationID: _, retryAfter: _) { }
        let after = try await service.foodCoverage(reviewed: pantry, delivery: delivery)
        XCTAssertEqual(after.needs.first(where: { $0.groupIds == [group] })?.reservations?.first?.backed.formatted, "2")
        let stored = try await save(.storeDelivery(source: source, location: "pantry", storedAt: Date(), useFirstAt: nil))
        XCTAssertEqual(stored.lotId, source)
        let alias = try XCTUnwrap(pantry.lots.first(where: { $0.id == source }))
        XCTAssertEqual(alias.observation?.quantity, delivery.sources.first(where: { $0.id == source })?.confirmed?.quantity)
        _ = try await save(.select(lot: source, selected: true))
        _ = try await save(.match(lot: source, ingredient: target, matched: true))
        let joined = try await service.foodCoverage(reviewed: pantry, delivery: delivery)
        let combined = try XCTUnwrap(joined.needs.first(where: { $0.groupIds == [group] }))
        XCTAssertEqual(combined.freezer?.formatted, "2")
        XCTAssertEqual(combined.pantry?.formatted, "7")
        XCTAssertEqual(combined.delivered?.formatted, "0")
        XCTAssertEqual(combined.covered?.formatted, "9")
        try await exerciseRecovery(service, scope: scope, occurrence: occurrence, delivery: delivery, lot: lot)
    }

    private func exerciseRecovery(_ service: HouseholdService, scope: HouseholdBootstrap, occurrence: SharedMealOccurrence,
                                  delivery: SharedDeliveryPage, lot: UUID) async throws {
        let id = delivery.shopId.uuidString.lowercased()
        let facts = try await service.mealRecoveryFacts(shopID: id), desk = facts.page
        XCTAssertEqual(desk.base.recoveryRevision, 0)
        let original = try XCTUnwrap(desk.meals.first(where: { $0.id == occurrence.id }))
        XCTAssertEqual(desk.mealSources.first?.sealedRevisionId, original.revisionId)
        XCTAssertEqual(desk.targetDigests.first?.digest, try original.targetDigest())
        XCTAssertEqual(original.day, "2099-11-01")
        XCTAssertEqual(original.zone, deadline.zone)
        XCTAssertEqual(original.due, deadline.at)
        XCTAssertFalse(original.needs.isEmpty)
        XCTAssertTrue(original.needs.allSatisfy { $0.due == deadline.at })
        var replacement = original
        replacement.title = "Bean supper / frijoles"
        replacement.notes = "Use the freezer beans.\nCocer a fuego lento."
        replacement.revisionId = UUID()
        for index in replacement.needs.indices where replacement.needs[index].priority == "required" {
            replacement.needs[index].id = UUID(); replacement.needs[index].ingredientId = UUID()
            replacement.needs[index].matchedSourceIds = [lot]
        }
        let intent = SharedRecoveryIntent(occurrenceId: occurrence.id, targetDigest: try original.targetDigest(), replacement: replacement,
            reviewedAt: desk.asOf, repeatOfOccurrenceId: nil, agreesToRepeat: false, proposesExtraTrip: false,
            agreesToExtraTrip: false, acceptsUnresolved: true)
        let coverage = try await service.effectiveCoverage(reviewed: desk)
        XCTAssertEqual(Set(coverage.needs.map(\.needId)), Set(original.needs.map(\.id)))
        let preview = try await service.previewMealRecovery(intent, reviewed: desk)
        XCTAssertTrue(preview.consentSatisfied); XCTAssertFalse(preview.feasible)
        XCTAssertFalse(preview.foodConfirmed); XCTAssertFalse(preview.timingConfirmed)
        let window = try await service.replayWindow()
        func operation(_ kind: String, _ fields: [String: JSONValue]) async throws -> PendingOperation {
            try await service.prepare(envelope: .init(replayWindow: window.id, shopId: id, kind: kind,
                base: .init(shopRevision: desk.base.shopRevision, authorityEpoch: desk.base.authorityEpoch), body: fields), bootstrap: scope)
        }
        let unchanged = SharedCookCopyEdit.save(text: "Original meal from the recovery desk", language: "en", occurrence: occurrence)
        let unchangedFields = try unchanged.body(reviewed: facts.delivery, pantry: facts.pantry, recovery: desk)
        XCTAssertNil(unchangedFields["revisionId"]); XCTAssertNil(unchangedFields["recoveryRevision"])
        let originalCopy = try await operation(unchanged.kind, unchangedFields)
        _ = try await service.executeSharedShop(originalCopy)
        let applied = try await operation("mealRecovery.apply", intent.commandBody(reviewed: desk, preview: preview))
        let first = try await service.executeSharedShop(applied)
        let replay = try await service.executeSharedShop(applied)
        XCTAssertEqual(first, replay); XCTAssertEqual(first.revisionId, replacement.revisionId)
        let updated = try await service.mealRecoveryFacts(shopID: id)
        XCTAssertEqual(updated.page.base.recoveryRevision, desk.base.recoveryRevision + 1)
        XCTAssertEqual(updated.delivery.recoveryRevision, updated.page.base.recoveryRevision)
        XCTAssertEqual(updated.page.base.supplyRevision, desk.base.supplyRevision + 1)
        XCTAssertEqual(updated.page.base.pantryRevision, desk.base.pantryRevision + 1)
        XCTAssertEqual(updated.page.meals.first, replacement)
        XCTAssertEqual(updated.delivery.meals, delivery.meals)
        let current = try await service.effectiveCoverage(reviewed: updated.page)
        XCTAssertEqual(Set(current.needs.map(\.needId)), Set(replacement.needs.map(\.id)))
        XCTAssertEqual(current.needs.first(where: { $0.protected })?.reservations?.first?.backed.formatted, "2")
        let copy = SharedCookCopyEdit.save(text: replacement.notes, language: "es", occurrence: occurrence)
        let legacy = try await operation(copy.kind, copy.body(reviewed: updated.delivery, pantry: updated.pantry))
        do { _ = try await service.executeSharedShop(legacy); XCTFail("Saved changed dinner without its revision") }
        catch ClientError.service(status: 409, code: _, correlationID: _, retryAfter: _) {}
        let sealed = try await operation(copy.kind, copy.body(reviewed: updated.delivery, pantry: updated.pantry, recovery: updated.page))
        let receipt = try await service.executeSharedShop(sealed)
        let history = try await service.cookCopies(occurrence: occurrence, reviewed: updated.delivery)
        XCTAssertEqual(history.first?.id, receipt.copyId); XCTAssertEqual(history.first?.revisionId, replacement.revisionId)
        XCTAssertEqual(history.first?.recoveryRevision, first.recoveryRevision)
        XCTAssertEqual(history.first?.text, replacement.notes)
        XCTAssertTrue(history.contains { $0.revisionId == nil && $0.text == "Keep five grams apart" })
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

extension SharedMealNativeWireTests {
    private func exerciseFallback(_ service: HouseholdService, shop: UUID, scope: HouseholdBootstrap) async throws {
        let id = shop.uuidString.lowercased()
        let facts = try await service.mealRecoveryFacts(shopID: id), desk = facts.page
        let target = try XCTUnwrap(desk.meals.first(where: { $0.due != nil }))
        let source = try XCTUnwrap(desk.sourceOptions.first(where: { $0.quantity?.unit == "count" }))
        XCTAssertEqual(source.quantity?.amount, .init(numerator: 5))
        var library = try await service.acceptedFallbacks(shopID: id)
        XCTAssertTrue(library.candidates.isEmpty)
        let chosenMeal = SharedFallbackSource.meal(occurrenceId: target.id, mealRevision: target.sourceMealRevision, revisionId: target.revisionId)
        let projected = try await service.fallbackSource(chosenMeal, reviewed: library)
        XCTAssertEqual(projected.recipe.title, target.title)
        XCTAssertEqual(projected.recipe.groups?.count, target.groups.count)
        func count(_ n: Int) -> SharedMealQuantity { .init(amount: .init(numerator: n), unit: "count", originalLiteral: String(n)) }
        func recipe(_ n: Int, _ title: String) -> SharedFallbackRecipe {
            .init(title: title, portions: 4, notes: "Serve warm", sourceURL: nil, exclusions: [], requiredLeadMinutes: nil,
                  elapsedMinutes: 10, ingredients: [.init(id: UUID(), name: "Wraps", quantity: count(n), exclusions: [], notes: "Warm the wraps")])
        }
        let easy = recipe(3, "Three warm wraps"), bigger = recipe(6, target.title)
        let easyID = UUID(), biggerID = UUID()
        let pending = try await service.prepareFallback(.accept(candidateId: easyID, baseRevision: nil, source: .disclosed,
            recipe: easy, usual: true), reviewed: library, clientKey: UUID())
        let durable = try JSONDecoder().decode(PendingFallbackWrite.self, from: JSONEncoder().encode(pending))
        try durable.validate()
        let accepted = try await service.executeFallback(durable)
        library = try await service.acceptedFallbacks(shopID: id)
        XCTAssertTrue(library.belongsToSameDevice(as: durable))
        _ = try await service.saveFallback(.accept(candidateId: biggerID, baseRevision: nil, source: .disclosed, recipe: bigger, usual: false),
                                          reviewed: library, clientKey: UUID())
        let replay = try await service.executeFallback(durable)
        XCTAssertEqual(replay, accepted)
        library = try await service.acceptedFallbacks(shopID: id)
        func review(_ cid: UUID, _ candidate: SharedFallbackRecipe, offer: SharedFallbackOffer? = nil, unknownTime: Bool = false) -> SharedFallbackReview {
            .init(candidateId: cid, revision: 1, remainingElapsedMinutes: nil, remainingTimeUnknown: unknownTime, advanceStepsCompleted: false,
                  ingredients: [.init(ingredientId: candidate.ingredients[0].id, sourceIds: [source.id], offer: offer)])
        }
        let offer = SharedFallbackOffer(label: "Two wraps", exclusionTags: [], usablePerPack: count(2), priceMinor: 200, availablePacks: 2)
        let trip = SharedFallbackTrip(minutes: 8, budgetMinor: 500, chargesMinor: 50, currency: "USD")
        let ranking = try await service.recoveryOptions([review(biggerID, bigger, offer: offer), review(easyID, easy)], trip: trip,
                                                       for: target.id, reviewed: desk, library: library)
        XCTAssertEqual(ranking.options.map(\.id), [easyID,biggerID])
        XCTAssertEqual(ranking.usualMinutes, 10)
        let clearedTime = try await service.recoveryOptions([review(easyID, easy, unknownTime: true)], trip: nil,
                                                            for: target.id, reviewed: desk, library: library)
        XCTAssertEqual(clearedTime.target, target)
        XCTAssertTrue(clearedTime.options.isEmpty)
        XCTAssertNil(clearedTime.usualMinutes)
        XCTAssertEqual(clearedTime.conditional.map(\.reason), ["timingUnknown"])

        XCTAssertEqual(ranking.conditional, [])
        let topUp = try XCTUnwrap(ranking.options.last)
        XCTAssertEqual(topUp.buys.map(\.packs), [2])
        XCTAssertEqual(topUp.extraCashMinor, 450)
        XCTAssertEqual(topUp.minutes, 18)
        XCTAssertTrue(topUp.repeatRequired)
        let noTrip = try await service.recoveryOptions([review(biggerID, bigger)], trip: nil, for: target.id, reviewed: desk, library: library)
        XCTAssertEqual(noTrip.options, [])
        XCTAssertEqual(noTrip.conditional.first?.reason, "topUpUnreviewed")
        let blocked = try await service.previewMealRecovery(topUp.intent, reviewed: desk)
        XCTAssertFalse(blocked.consentSatisfied)
        _ = try await service.saveFallback(.revoke(candidateId: biggerID, baseRevision: 1), reviewed: library, clientKey: UUID())
        do {
            _ = try await service.previewMealRecovery(topUp.intent, reviewed: desk)
            XCTFail("Withdrawn candidate could still be previewed")
        } catch ClientError.service(status: 409, code: _, correlationID: _, retryAfter: _) {}
        let preLapseLibrary = try await service.acceptedFallbacks(shopID: id)
        let unsentApproval = try await service.prepareFallback(.accept(candidateId: UUID(), baseRevision: nil,
            source: .disclosed, recipe: bigger, usual: false), reviewed: preLapseLibrary, clientKey: UUID())
        let onHand = try XCTUnwrap(ranking.options.first)
        let preview = try await service.previewMealRecovery(onHand.intent, reviewed: desk)
        XCTAssertTrue(preview.feasible)
        let window = try await service.replayWindow()
        // Keep a second unconsumed preview so a new key after lapse reaches the live seat check.
        let unused = try await service.previewMealRecovery(onHand.intent, reviewed: desk)
        XCTAssertNotEqual(unused.previewId, preview.previewId)
        let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: id, kind: "mealRecovery.apply",
            base: .init(shopRevision: desk.base.shopRevision, authorityEpoch: desk.base.authorityEpoch),
            body: onHand.intent.commandBody(reviewed: desk, preview: preview)), bootstrap: scope)
        let applied = try await service.executeSharedShop(operation)
        let retry = try await service.executeSharedShop(operation)
        XCTAssertEqual(applied, retry)
        let expired = try await service.assistanceValidUntil(shopID: id)
        XCTAssertNil(expired)
        let saved = try await service.mealRecoveryFacts(shopID: id)
        XCTAssertEqual(saved.page.meals.first(where: { $0.id == target.id }), onHand.intent.replacement)
        let freeLibrary = try await service.acceptedFallbacks(shopID: id)
        XCTAssertTrue(freeLibrary.candidates.contains { $0.id == easyID })
        let recoveredApproval = try await service.executeFallback(durable)
        XCTAssertEqual(recoveredApproval, accepted)
        do {
            _ = try await service.executeFallback(unsentApproval)
            XCTFail("Expired member published a previously unsent household recipe")
        } catch ClientError.service(status: 403, code: "membership_inactive", correlationID: _, retryAfter: _) {}
        let afterRetry = try await service.acceptedFallbacks(shopID: id)
        XCTAssertEqual(afterRetry, freeLibrary)
        let newOperation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: id, kind: "mealRecovery.apply",
            base: .init(shopRevision: desk.base.shopRevision, authorityEpoch: desk.base.authorityEpoch),
            body: onHand.intent.commandBody(reviewed: desk, preview: unused)), bootstrap: scope)
        do {
            _ = try await service.executeSharedShop(newOperation)
            XCTFail("Expired member created a new assisted write")
        } catch ClientError.service(status: 403, code: "membership_inactive", correlationID: _, retryAfter: _) {}
        let stillSaved = try await service.mealRecoveryFacts(shopID: id)
        XCTAssertEqual(stillSaved.page.base, saved.page.base)
        try await exerciseFreeCloseout(service, shopID: id)
    }
}

extension SharedMealNativeWireTests {
    private func exerciseFreeCloseout(_ service: HouseholdService, shopID: String) async throws {
        let automatic = try await service.selectShop(nil)
        XCTAssertEqual(automatic.shopId, shopID)
        let delivery = try await service.deliveryEvidence(shopID: shopID)
        let coverage = try await service.deliveryCoverage(reviewed: delivery)
        XCTAssertTrue(coverage.needs.contains { $0.missing.map { $0.numerator != "0" } == true })
        let current = try await service.mealRecoveryFacts(shopID: shopID).page
        let effective = try await service.effectiveCoverage(reviewed: current)
        XCTAssertTrue(effective.needs.contains { $0.missing.map { $0.numerator != "0" } == true })
        let empty = try await service.shopperFinancialRecord(shopID: shopID)
        XCTAssertTrue(empty.entries.isEmpty)
        let date = Date().ISO8601Format()
        let charge = ShopperFinancialEntry(kind: .postedCharge, amountMinor: 3720, occurredAt: date, sourceText: "Net receipt $37.20")
        let chargeIntent = try await service.prepareFinancial(.append(charge), reviewed: empty)
        try await service.executeFinancial(chargeIntent)
        let recovered = try JSONDecoder().decode(ShopperFinancialIntent.self, from: JSONEncoder().encode(chargeIntent))
        try await service.executeFinancial(recovered)
        let charged = try await service.shopperFinancialRecord(shopID: shopID)
        XCTAssertEqual(charged.entries.map(\.id), [charge.id])
        let credit = UUID()
        let promised = ShopperFinancialEntry(kind: .pendingCredit, amountMinor: 240, occurredAt: date,
            sourceText: "Refund pending $2.40", creditId: credit, chargeEvidenceKey: charge.evidenceKey)
        try await service.executeFinancial(service.prepareFinancial(.append(promised), reviewed: charged))
        let pending = try await service.shopperFinancialRecord(shopID: shopID)
        XCTAssertEqual(pending.entries.map(\.amountMinor), [3720,240])
        let close = try await service.prepareFinancial(.close, reviewed: pending)
        try await service.executeFinancial(close)
        try await service.executeFinancial(close)
        let closed = try await service.shopperShop(shopID: shopID)
        XCTAssertEqual(closed.phase, "closed"); XCTAssertEqual(closed.placedRevision, delivery.placedRevision)
        let retained = try await service.shopperFinancialRecord(shopID: shopID)
        XCTAssertEqual(retained.entries, pending.entries)
        let included = ShopperFinancialEntry(kind: .includedCredit, amountMinor: 240, occurredAt: date,
            sourceText: "Statement confirms included in original net receipt", creditId: credit, chargeEvidenceKey: charge.evidenceKey)
        try await service.executeFinancial(service.prepareFinancial(.append(included), reviewed: retained))
        let final = try await service.shopperFinancialRecord(shopID: shopID)
        XCTAssertEqual(final.entries.map(\.kind), [.postedCharge,.pendingCredit,.includedCredit])
        XCTAssertEqual(final.entries.map(\.creditId), [nil,credit,credit])
        XCTAssertEqual(final.entries.map(\.chargeEvidenceKey), [nil,charge.evidenceKey,charge.evidenceKey])
        let after = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(after.meals, delivery.meals); XCTAssertEqual(after.sources, delivery.sources)
        let stillNeeded = try await service.deliveryCoverage(reviewed: after)
        XCTAssertEqual(coverage.needs, stillNeeded.needs)
        let reopened = try await service.mealRecoveryFacts(shopID: shopID).page
        XCTAssertEqual(current.meals, reopened.meals)
        let reopenedNeeds = try await service.effectiveCoverage(reviewed: reopened)
        XCTAssertEqual(effective.needs, reopenedNeeds.needs)
    }
}
