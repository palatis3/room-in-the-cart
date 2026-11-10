import XCTest
@testable import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedShopFlowTests: XCTestCase {
    private func model(_ actor: String, fixture: SharedFlowService, queue: URL? = nil) async throws -> HouseholdModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SharedFlowURLProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config))
        let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://identity.test")!, publishableKey: "sb_publishable_test"), vault: SharedFlowVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://household.test")!), auth: auth, deviceVault: SharedFlowVault(), transport: transport)
        SharedFlowURLProtocol.handler = fixture.respond
        let model = HouseholdModel(auth: auth, service: service, outboxURL: queue ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json"))
        model.email = actor + "@example.test"; model.code = "123456"; await model.verifyCode()
        XCTAssertNotNil(model.identity); return model
    }
    private func createdHousehold(_ fixture: SharedFlowService, queue: URL? = nil) async throws -> HouseholdModel {
        let model = try await model("mia", fixture: fixture, queue: queue)
        let lifecycle = try XCTUnwrap(model.lifecycle)
        lifecycle.householdLabel = "Our home"; lifecycle.alias = "Mia"; lifecycle.adultAttestation = true; lifecycle.keepLocalPrivate = true
        await lifecycle.createHousehold()
        XCTAssertEqual(model.projection?.role, "organizer"); XCTAssertNil(model.projection?.shopId)
        XCTAssertEqual(fixture.householdCreates, 1); return model
    }
    private func enterShop(_ model: HouseholdShopModel) {
        model.beginEditing()
        model.draft.lines = [.init(item: "Original basket", price: "37.20")]
        model.draft.complete = true; model.draft.cap = "38.00"
        model.draft.fee = "0"; model.draft.tax = "0"; model.draft.deposits = "0"; model.draft.discounts = "0"
        model.reviewDraft(); model.acknowledged = true
    }
    private func waitingAmendment() async throws -> (SharedFlowService, HouseholdModel, HouseholdShopModel, OperationOutbox, PendingOperation) {
        let fixture = SharedFlowService()
        let queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("amendment-retry.json")
        let adult = try await createdHousehold(fixture, queue: queue)
        let shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        fixture.phase = "placed"; fixture.placedRevision = fixture.revision; fixture.revision += 1
        await shared.load()
        let page = try await shared.confirmedOrder()
        let confirmation = SharedOrderConfirmation(reference: "Retailer cancelled this order", confirmedAt: Date(), lines: [])
        let envelope = CommandEnvelope(replayWindow: UUID().uuidString.lowercased(), shopId: try XCTUnwrap(fixture.shopID),
            kind: "amendment.recordResponse", base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch),
            body: try confirmation.body(reviewed: page))
        let operation = try PendingOperation(envelope: envelope, householdID: fixture.household, memberID: fixture.miaID, deviceID: "mia-device")
        // HouseholdModel deliberately separates contributor and shared-shop queues.
        // Seed the same durable store the shared model actually opens on restart.
        let outbox = OperationOutbox(url: queue.deletingPathExtension().appendingPathExtension("shared-shop.json"))
        try await outbox.append(operation)
        let persisted = try await outbox.operations(); XCTAssertEqual(persisted, [operation])
        await shared.load()
        XCTAssertEqual(shared.pending, operation)
        XCTAssertEqual(shared.delivery, .waiting)
        XCTAssertFalse(shared.reviewedCurrentFacts)
        return (fixture, adult, shared, outbox, operation)
    }
    func testTrackingShopConflictRefreshEnablesSameBytesRetryWithoutClear() async throws { try await trackingRecovery(inbox: false, undo: false) }
    func testRequestUndoShopConflictRefreshEnablesSameBytesRetryWithoutClear() async throws { try await trackingRecovery(inbox: false, undo: true) }
    func testTrackingInboxConflictRefreshEnablesSameBytesRetryWithoutClear() async throws { try await trackingRecovery(inbox: true, undo: false) }
    func testRequestUndoInboxConflictRefreshEnablesSameBytesRetryWithoutClear() async throws { try await trackingRecovery(inbox: true, undo: true) }
    func testTrackingShopHeldRefreshCannotRestoreRetryAcrossShopSelection() async throws { try await trackingRecovery(inbox: false, undo: false, invalidateHeld: true) }
    func testRequestUndoInboxHeldRefreshCannotRestoreRetryAfterScopeClear() async throws { try await trackingRecovery(inbox: true, undo: true, invalidateHeld: true) }
    private func trackingRecovery(inbox useInbox: Bool, undo: Bool, invalidateHeld: Bool = false) async throws {
        let fixture = SharedFlowService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); SharedFlowURLProtocol.heldRead = nil }
        let queue = directory.appendingPathComponent("tracking-recovery.json"), adult = try await createdHousehold(fixture, queue: queue)
        let shared = try XCTUnwrap(adult.sharedShop); enterShop(shared); await shared.applyReviewed()
        let shop = try XCTUnwrap(shared.shop), service = shared.trackingService
        let context = try await service.sharedDemandContext(shopID: UUID(uuidString: shop.shopId)!)
        let operation: PendingOperation
        if undo {
            let target = SharedDemandID(), request = SharedDemandID(), reserved = SharedDemandID()
            let actionJSON: [String: Any] = ["kind": "request.undoAcceptance", "body": ["targetOperationId": target.string, "requestId": request.string,
                "baseRequestRevision": 4, "lines": try JSONSerialization.jsonObject(with: JSONEncoder().encode(shop.lines)), "quote": try JSONSerialization.jsonObject(with: JSONEncoder().encode(shop.quote))]]
            let action = try JSONDecoder().decode(SharedRequestUndoAction.self, from: fixture.data(actionJSON))
            let digest = try JSONDecoder().decode(SharedRequestUndoDigest.self, from: JSONEncoder().encode(String(repeating: "a", count: 64)))
            let binding = SharedRequestUndoOperationBinding(context: context, shopID: .init(UUID(uuidString: shop.shopId)!), targetOperationID: target,
                reservedOperationID: reserved, previewID: .init(), previewDigest: digest,
                base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, requestRevision: 4), action: action)
            operation = try .init(envelope: .init(replayWindow: UUID().uuidString.lowercased(), shopId: shop.shopId, kind: "request.undoAcceptance", base: binding.base, body: binding.body()),
                householdID: context.householdID, memberID: context.memberID, deviceID: context.deviceID, sharedRequestUndoBinding: binding)
        } else {
            let action = try SharedTrackingAction(.patch(.init(quote: shop.quote, lines: shop.lines)))
            let binding = SharedTrackingOperationBinding(kind: .apply, mode: "review", context: context, shopID: .init(UUID(uuidString: shop.shopId)!),
                base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch), graphRevision: 2, privacyRevision: 0,
                stateDigest: String(repeating: "a", count: 64), previewID: .init(), previewDigest: String(repeating: "b", count: 64), action: action, targetOperationID: nil)
            operation = try .init(envelope: .init(replayWindow: UUID().uuidString.lowercased(), shopId: shop.shopId, kind: "shop.patch", base: binding.base, body: binding.body()),
                householdID: context.householdID, memberID: context.memberID, deviceID: context.deviceID, sharedTrackingBinding: binding)
        }
        let outbox = OperationOutbox(url: useInbox ? directory.appendingPathComponent("inbox-pending.json") : queue.deletingPathExtension().appendingPathExtension("shared-shop.json"))
        let inbox = HouseholdInboxModel(bootstrap: shared.scope, service: service, outbox: outbox, onAccessEnded: {})
        var posted: [Data] = []
        SharedFlowURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/commands") {
                let bytes = try fixture.body(request), envelope = try JSONDecoder().decode(CommandEnvelope.self, from: bytes)
                if envelope.clientKey == operation.clientKey {
                    posted.append(bytes)
                    return (409, try fixture.data(["error": ["code": "refresh_required"]]))
                }
            }
            return try fixture.respond(request)
        }
        func load() async { if useInbox { await inbox.load() } else { await shared.load() } }
        func retry() async { if useInbox { await inbox.retry() } else { await shared.retry() } }
        func clear() async { if useInbox { await inbox.clearPendingAfterReview() } else { await shared.clearPendingAfterReview() } }
        func pending() -> PendingOperation? { useInbox ? inbox.pending : shared.pending }
        func delivery() -> ShopperDelivery { useInbox ? inbox.delivery : shared.delivery }
        try await outbox.append(operation); await load(); XCTAssertEqual(delivery(), .waiting)
        await retry(); XCTAssertEqual(delivery(), .needsReview); XCTAssertEqual(pending(), operation)
        XCTAssertEqual(posted, [operation.bytes])
        if invalidateHeld {
            let arrived = expectation(description: "held parent current-shop refresh")
            let held = SharedFlowHeldRead(pathSuffix: "/shops/" + shop.shopId, arrived: { arrived.fulfill() })
            SharedFlowURLProtocol.heldRead = held
            let loading = Task { await load() }; await fulfillment(of: [arrived], timeout: 2)
            if useInbox { inbox.clear() }
            else {
                var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shared.scope)) as! [String: Any]
                raw["shopId"] = UUID().uuidString.lowercased()
                shared.updateScope(try JSONDecoder().decode(HouseholdBootstrap.self, from: fixture.data(raw)))
            }
            held.release(); await loading.value
            XCTAssertNil(pending()); await retry(); XCTAssertEqual(posted, [operation.bytes])
        } else {
            await load(); XCTAssertEqual(delivery(), .waiting); XCTAssertEqual(pending(), operation)
            await clear(); XCTAssertEqual(pending(), operation)
            let beforeRetry = try await outbox.operations(); XCTAssertEqual(beforeRetry, [operation])
            await retry(); XCTAssertEqual(posted, [operation.bytes, operation.bytes]); XCTAssertEqual(delivery(), .needsReview)
            XCTAssertEqual(pending(), operation)
        }
        let persisted = try await outbox.operations(); XCTAssertEqual(persisted, [operation]); XCTAssertEqual(persisted[0].bytes, operation.bytes)
    }
    func testTrackingPendingShopSwitchCannotDiscardOtherShopAndRestoresExactBytes() async throws {
        let fixture = SharedFlowService()
        let queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tracking.json")
        let adult = try await createdHousehold(fixture, queue: queue)
        let shared = try XCTUnwrap(adult.sharedShop); enterShop(shared); await shared.applyReviewed()
        let originalShop = try XCTUnwrap(shared.shop), originalScope = shared.scope
        let action = try SharedTrackingAction(.patch(.init(quote: originalShop.quote, lines: originalShop.lines)))
        let binding = SharedTrackingOperationBinding(kind: .apply, mode: "review",
            context: .init(subject: "mia", householdID: fixture.household, memberID: fixture.miaID, deviceID: "mia-device"),
            shopID: .init(UUID(uuidString: originalShop.shopId)!), base: .init(shopRevision: originalShop.shopRevision, authorityEpoch: originalShop.authorityEpoch),
            graphRevision: 2, privacyRevision: 0, stateDigest: String(repeating: "a", count: 64), previewID: .init(),
            previewDigest: String(repeating: "b", count: 64), action: action, targetOperationID: nil)
        let operation = try PendingOperation(envelope: .init(replayWindow: UUID().uuidString.lowercased(), shopId: originalShop.shopId,
            kind: "shop.patch", base: binding.base, body: binding.body()), householdID: fixture.household,
            memberID: fixture.miaID, deviceID: "mia-device", sharedTrackingBinding: binding)
        let outboxURL = queue.deletingPathExtension().appendingPathExtension("shared-shop.json")
        let outbox = OperationOutbox(url: outboxURL); try await outbox.append(operation); await shared.load()
        XCTAssertEqual(shared.pending, operation)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(originalScope)) as! [String: Any]
        let other = UUID().uuidString.lowercased(); raw["shopId"] = other
        let otherScope = try JSONDecoder().decode(HouseholdBootstrap.self, from: JSONSerialization.data(withJSONObject: raw))
        fixture.shopID = other; shared.updateScope(otherScope); XCTAssertNil(shared.pending)
        await shared.load(); XCTAssertNil(shared.pending)
        let sent = fixture.kinds.count; await shared.retry(); await shared.clearPendingAfterReview()
        XCTAssertEqual(fixture.kinds.count, sent)
        let reopened = OperationOutbox(url: outboxURL), persisted = try await reopened.operations()
        XCTAssertEqual(persisted, [operation]); XCTAssertEqual(persisted[0].bytes, operation.bytes)
        fixture.shopID = originalShop.shopId; shared.updateScope(originalScope); await shared.load()
        XCTAssertEqual(shared.pending, operation); XCTAssertEqual(shared.pending?.bytes, operation.bytes)
        XCTAssertFalse(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        XCTAssertEqual(shared.pending, operation)
        let stillSaved = try await reopened.operations(); XCTAssertEqual(stillSaved, [operation])
    }

    func testErasedAmendmentEvidenceAllowsExplicitLocalRetryClearWithoutResubmitting() async throws {
        let (fixture, _, shared, outbox, operation) = try await waitingAmendment()
        fixture.confirmedOrderFailure = (409, "order_evidence_removed")
        do { _ = try await shared.confirmedOrder(); XCTFail("Erased evidence must remain unavailable") }
        catch ClientError.service(status: 409, code: "order_evidence_removed", correlationID: _, retryAfter: _) {}
        XCTAssertEqual(shared.pending, operation)
        XCTAssertEqual(shared.delivery, .needsReview)
        XCTAssertTrue(shared.reviewedCurrentFacts)
        XCTAssertNotNil(shared.notice)
        // Refresh does not forget the exact terminal outcome already reviewed.
        await shared.load()
        XCTAssertTrue(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        XCTAssertNil(shared.pending); XCTAssertFalse(shared.reviewedCurrentFacts)
        let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(fixture.kinds.contains("amendment.recordResponse"))
    }
    func testUncertainConfirmedOrderReadNeverAuthorizesClearingPendingAmendment() async throws {
        let (fixture, _, shared, outbox, operation) = try await waitingAmendment()
        fixture.confirmedOrderFailure = (503, "service_unavailable")
        do { _ = try await shared.confirmedOrder(); XCTFail("Unavailable read must fail") }
        catch ClientError.service(status: 503, code: _, correlationID: _, retryAfter: _) {}
        XCTAssertFalse(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        XCTAssertEqual(shared.pending, operation)
        let remaining = try await outbox.operations(); XCTAssertEqual(remaining, [operation])
    }
    func testAmendmentRetryStaysWithItsOriginalShopAcrossSelectionAndReviewReset() async throws {
        let (fixture, adult, shared, outbox, operation) = try await waitingAmendment()
        let originalShop = try XCTUnwrap(fixture.shopID)
        _ = try await shared.confirmedOrder()
        XCTAssertTrue(shared.reviewedCurrentFacts)
        fixture.shopID = UUID().uuidString.lowercased()
        await shared.load()
        XCTAssertNil(shared.pending); XCTAssertFalse(shared.reviewedCurrentFacts)
        _ = try await shared.confirmedOrder()
        XCTAssertFalse(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        let retained = try await outbox.operations(); XCTAssertEqual(retained, [operation])
        fixture.shopID = originalShop
        await shared.load()
        XCTAssertEqual(shared.pending, operation)
        XCTAssertFalse(shared.reviewedCurrentFacts, "A review of another shop must never clear this action")
        fixture.confirmedOrderFailure = (409, "order_evidence_removed")
        do { _ = try await shared.confirmedOrder() } catch {}
        XCTAssertTrue(shared.reviewedCurrentFacts)
        adult.lock()
        XCTAssertNil(shared.pending); XCTAssertFalse(shared.reviewedCurrentFacts)
        let stillSaved = try await outbox.operations(); XCTAssertEqual(stillSaved, [operation])
    }
    func testDeliveryRetryStaysWithOriginalShopAndCannotBeClearedByAnotherShopsFacts() async throws {
        let fixture = SharedFlowService()
        let queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("delivery-scope.json")
        let adult = try await createdHousehold(fixture, queue: queue), shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        fixture.placedRevision = fixture.revision; fixture.phase = "closed"; fixture.revision += 1
        await shared.load(); await shared.loadDelivery()
        let page = try XCTUnwrap(shared.deliveryRecord), line = try XCTUnwrap(page.lines.first)
        let originalShop = try XCTUnwrap(fixture.shopID)
        let edit = SharedDeliveryEdit.register(lineID: line.id, segment: UUID(), name: line.name, exclusions: [])
        let envelope = CommandEnvelope(replayWindow: UUID().uuidString.lowercased(), shopId: originalShop, kind: edit.kind,
            base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: try edit.body(reviewed: page))
        let operation = try PendingOperation(envelope: envelope, householdID: fixture.household, memberID: fixture.miaID, deviceID: "mia-device")
        let outbox = OperationOutbox(url: queue.deletingPathExtension().appendingPathExtension("shared-shop.json"))
        try await outbox.append(operation)
        await shared.load(); await shared.loadDelivery()
        XCTAssertEqual(shared.pending, operation); XCTAssertTrue(shared.reviewedCurrentFacts)
        let sentBefore = fixture.commandBodies.count
        fixture.shopID = UUID().uuidString.lowercased()
        await shared.load(); await shared.loadDelivery()
        XCTAssertNil(shared.pending); XCTAssertFalse(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        let retained = try await outbox.operations()
        XCTAssertEqual(retained, [operation], "Another shop's delivery facts cannot erase the original durable intent")
        XCTAssertEqual(fixture.commandBodies.count, sentBefore)
        await shared.retry()
        XCTAssertEqual(fixture.commandBodies.count, sentBefore)
        fixture.shopID = originalShop
        await shared.load()
        XCTAssertEqual(shared.pending, operation); XCTAssertFalse(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        XCTAssertEqual(shared.pending, operation)
        await shared.loadDelivery()
        XCTAssertTrue(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        let cleared = try await outbox.operations()
        XCTAssertNil(shared.pending); XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(fixture.commandBodies.count, sentBefore)
    }
    func testClosedSharedPickupRecordsLateArrivalAndCorrectionWithoutChangingOrderOrClosure() async throws {
        let fixture = SharedFlowService(), adult = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        fixture.placedRevision = fixture.revision; fixture.phase = "closed"; fixture.revision += 1
        await shared.load(); await shared.loadDelivery()
        let original = try XCTUnwrap(shared.shop), initial = try XCTUnwrap(shared.deliveryRecord)
        let line = try XCTUnwrap(initial.lines.first)
        let saved1 = await shared.saveDelivery(.register(lineID: line.id, segment: UUID(), name: line.name, exclusions: []), reviewed: initial)
        XCTAssertTrue(saved1)
        await shared.loadDelivery()
        let registered = try XCTUnwrap(shared.deliveryRecord), source = try XCTUnwrap(registered.sources.first)
        let arrival = UUID(), quantity = SharedMealQuantity(amount: .init(numerator: 6, denominator: 1), unit: "count", originalLiteral: "6")
        let saved2 = await shared.saveDelivery(.arrival(source: source.id, previous: nil, observation: arrival,
            date: Date().addingTimeInterval(-10), received: quantity), reviewed: registered)
        XCTAssertTrue(saved2)
        await shared.loadDelivery()
        let arrived = try XCTUnwrap(shared.deliveryRecord)
        XCTAssertNil(arrived.sources.first?.confirmed)
        let usable = UUID()
        let saved3 = await shared.saveDelivery(.usable(source: source.id, previous: nil, arrival: arrival, observation: usable,
            date: Date(), quantity: quantity), reviewed: arrived)
        XCTAssertTrue(saved3)
        await shared.loadDelivery()
        let reviewed = try XCTUnwrap(shared.deliveryRecord)
        let reduced = SharedMealQuantity(amount: .init(numerator: 3, denominator: 1), unit: "count", originalLiteral: "3")
        let saved4 = await shared.saveDelivery(.usable(source: source.id, previous: usable, arrival: arrival, observation: UUID(),
            date: Date(), quantity: reduced), reviewed: reviewed)
        XCTAssertTrue(saved4)
        await shared.loadDelivery()
        XCTAssertEqual(shared.deliveryRecord?.sources.first?.confirmed?.quantity, reduced)
        XCTAssertEqual(shared.deliveryRecord?.supplyRevision, 4)
        XCTAssertEqual(shared.shop, original)
        let before = fixture.commandBodies.count
        let saved5 = await shared.saveDelivery(.arrival(source: source.id, previous: nil, observation: UUID(),
            date: Date(), received: quantity), reviewed: registered)
        XCTAssertFalse(saved5)
        XCTAssertEqual(fixture.commandBodies.count, before, "Stale delivery review cannot send a correction")
        shared.reviewPhaseChange("shop.reopen")
        XCTAssertNil(shared.review)
    }
    func testLostClosedArrivalReplyRestoresExactDurableCommandWithoutSecondDelivery() async throws {
        let fixture = SharedFlowService()
        let queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("closed-delivery.json")
        let adult = try await createdHousehold(fixture, queue: queue), shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        fixture.placedRevision = fixture.revision; fixture.phase = "closed"; fixture.revision += 1
        await shared.load(); await shared.loadDelivery()
        let initial = try XCTUnwrap(shared.deliveryRecord), line = try XCTUnwrap(initial.lines.first)
        let saved6 = await shared.saveDelivery(.register(lineID: line.id, segment: UUID(), name: line.name, exclusions: []), reviewed: initial)
        XCTAssertTrue(saved6)
        await shared.loadDelivery()
        let registered = try XCTUnwrap(shared.deliveryRecord), source = try XCTUnwrap(registered.sources.first)
        fixture.loseDeliveryResponse = true
        let saved7 = await shared.saveDelivery(.arrival(source: source.id, previous: nil, observation: UUID(), date: Date(), received: nil), reviewed: registered)
        XCTAssertTrue(saved7)
        let pending = try XCTUnwrap(shared.pending)
        XCTAssertEqual(shared.delivery, .waiting)
        fixture.loseDeliveryResponse = false
        let outbox = OperationOutbox(url: queue.deletingPathExtension().appendingPathExtension("shared-shop.json"))
        let restored = HouseholdShopModel(scope: shared.scope, service: try XCTUnwrap(adult.service), outbox: outbox, onConfirmed: {}, onAccessEnded: {})
        await restored.load(); await restored.retry(); await restored.loadDelivery()
        XCTAssertNil(restored.pending); XCTAssertEqual(restored.shop?.phase, "closed")
        XCTAssertEqual(restored.deliveryRecord?.sources.count, 1); XCTAssertEqual(restored.deliveryRecord?.supplyRevision, 2)
        XCTAssertEqual(fixture.commandBodies.filter { $0.kind == "delivery.arrival" }.map(\.bytes), [pending.bytes, pending.bytes])
    }
    func testExcludedDeliveryMatchIsRejectedWithoutReportingSuccessOrDiscardingPendingReview() async throws {
        try await assertExcludedMatchIsRejected(pantry: false)
    }
    func testExcludedPantryMatchKeepsTheSameNoticeAndDurableReviewCleanup() async throws {
        try await assertExcludedMatchIsRejected(pantry: true)
    }
    private func assertExcludedMatchIsRejected(pantry: Bool) async throws {
        let fixture = SharedFlowService()
        let queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("excluded-match.json")
        let adult = try await createdHousehold(fixture, queue: queue), shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        let ingredient = SharedMealPlanning.Ingredient(name: "Milk", quantity: nil, groupIds: [], exclusions: ["dairy"])
        let meal = SharedMeal(title: "Dinner", day: "2026-11-05", kind: "dinner", portions: 3, protected: false,
            planning: .init(groups: [], ingredients: [ingredient]))
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: UUID(), meal: meal)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        fixture.placedRevision = fixture.revision; fixture.phase = "placed"; fixture.revision += 1
        fixture.pantryAvailable = pantry
        if pantry {
            fixture.pantryLots = [["lotId": UUID().uuidString.lowercased(), "origin": "manual", "location": "pantry",
                "storedAt": NSNull(), "useFirstAt": NSNull(), "foodName": "Milk", "exclusionTags": ["dairy"],
                "selected": true, "observation": NSNull(), "matches": [], "reservations": []]]
        }
        await shared.load(); await shared.loadDelivery()
        if !pantry {
            let initial = try XCTUnwrap(shared.deliveryRecord), line = try XCTUnwrap(initial.lines.first)
            let registered = await shared.saveDelivery(.register(lineID: line.id, segment: UUID(), name: "Milk", exclusions: ["dairy"]), reviewed: initial)
            XCTAssertTrue(registered)
            await shared.loadDelivery()
        }
        let page = try XCTUnwrap(shared.deliveryRecord), occurrence = try XCTUnwrap(page.meals?.first)
        let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
        let outbox = OperationOutbox(url: queue.deletingPathExtension().appendingPathExtension("shared-shop.json"))
        let receiptCount = fixture.receipts.count, supplyRevision = fixture.supplyRevision
        fixture.rejectExcludedMatch = true
        let saved: Bool
        if pantry {
            await shared.loadPantry(reviewed: page)
            let record = try XCTUnwrap(shared.pantryRecord), lot = try XCTUnwrap(record.lots.first)
            saved = await shared.savePantry(.match(lot: lot.id, ingredient: target, matched: true), reviewed: record, delivery: page)
            XCTAssertEqual(shared.pantryRecord, record)
            XCTAssertTrue(shared.pantryRecord?.lots.first?.matches.isEmpty == true)
        } else {
            let source = try XCTUnwrap(page.sources.first)
            saved = await shared.saveDelivery(.match(source: source.id, ingredient: target, matched: true), reviewed: page)
            XCTAssertTrue(shared.deliveryRecord?.sources.first?.matches?.isEmpty == true)
        }
        XCTAssertFalse(saved, "A terminal rejection must never close the editor as a successful match")
        XCTAssertEqual(shared.delivery, .needsReview)
        XCTAssertEqual(shared.notice, ht("This food conflicts with an exclusion for this ingredient. The match was not saved. Review the food and ingredient exclusions before trying another match."))
        XCTAssertNil(shared.review); XCTAssertFalse(shared.acknowledged); XCTAssertFalse(shared.reviewedCurrentFacts)
        XCTAssertEqual(shared.deliveryRecord, page)
        XCTAssertEqual(fixture.supplyRevision, supplyRevision); XCTAssertEqual(fixture.receipts.count, receiptCount)
        let operation = try XCTUnwrap(shared.pending)
        let kind = pantry ? "pantry.match" : "delivery.match"
        let sent = fixture.commandBodies.filter { $0.kind == kind }
        XCTAssertEqual(sent.map(\.bytes), [operation.bytes], "The rejection must come from the submitted HTTP command")
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        XCTAssertEqual(envelope.kind, kind); XCTAssertEqual(envelope.body["matched"], .bool(true))
        let retained = try await outbox.operations(); XCTAssertEqual(retained, [operation])
        await shared.retry(); await shared.clearPendingAfterReview()
        XCTAssertEqual(shared.pending, operation)
        XCTAssertEqual(fixture.commandBodies.filter { $0.kind == kind }.count, 1)
        let stillRetained = try await outbox.operations(); XCTAssertEqual(stillRetained, [operation])
        await shared.loadDelivery()
        if pantry { await shared.loadPantry(reviewed: try XCTUnwrap(shared.deliveryRecord)) }
        XCTAssertTrue(shared.reviewedCurrentFacts)
        await shared.clearPendingAfterReview()
        XCTAssertNil(shared.pending); XCTAssertEqual(shared.delivery, .none)
        let cleared = try await outbox.operations(); XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(fixture.commandBodies.filter { $0.kind == kind }.count, 1)
    }
    func testFreshHouseholdNativeFlowCreatesInvitesReceivesApprovesFreezesAndReopens() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); XCTAssertTrue(shared.canCreate)
        enterShop(shared); await shared.applyReviewed()
        XCTAssertEqual(mia.projection?.role, "shopper"); XCTAssertEqual(shared.shop?.lines.count, 1)
        XCTAssertFalse(shared.canCreate); XCTAssertNotNil(mia.shopperInbox)
        let people = try XCTUnwrap(mia.lifecycle); await people.createAdultInvitation()
        let invitation = try XCTUnwrap(people.issued)
        let sam = try await model("sam", fixture: fixture); let join = try XCTUnwrap(sam.lifecycle)
        join.alias = "Sam"; join.invitationCode = invitation.token; join.adultAttestation = true; join.keepLocalPrivate = true
        await join.redeemInvitation()
        XCTAssertEqual(sam.projection?.role, "contributor"); XCTAssertNil(sam.sharedShop); XCTAssertNil(sam.shopperInbox)
        sam.item = "Cereal"; sam.quantity = "one box"; await sam.sendRequest()
        let inbox = try XCTUnwrap(mia.shopperInbox); await inbox.load()
        XCTAssertEqual(inbox.requests.first?.authorAlias, "Sam")
        inbox.select(try XCTUnwrap(inbox.requests.first)); inbox.choice = .add; inbox.price = "3.49"; await inbox.review()
        XCTAssertEqual(inbox.preview?.after.totalMinor, 4069); XCTAssertEqual(inbox.preview?.after.overCapMinor, 269)
        XCTAssertFalse(inbox.canApply); inbox.acceptOverage = true; await inbox.apply()
        XCTAssertEqual(inbox.shop?.lines.count, 2)
        XCTAssertNil(inbox.trackingRequest, "An ordinary pickup must not require adoption of food tracking.")
        XCTAssertEqual(fixture.kinds.filter { $0 == "request.apply" }.count, 1)
        await shared.load(); shared.reviewPhaseChange("shop.freeze"); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.phase, "frozen")
        sam.item = "Milk"; sam.quantity = "one carton"; await sam.sendRequest()
        XCTAssertEqual(sam.requests.first { $0.originalItem == "Milk" }?.route, "next")
        shared.reviewPhaseChange("shop.reopen"); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.phase, "draft"); XCTAssertEqual(shared.shop?.lines.count, 2)
        await inbox.load(); let late = try XCTUnwrap(inbox.requests.first { $0.originalItem == "Milk" })
        XCTAssertEqual(late.route, "next")
        inbox.select(late); inbox.choice = .add; inbox.price = "2.00"; inbox.promote = true
        await inbox.review(); inbox.acceptOverage = true; await inbox.apply()
        XCTAssertEqual(inbox.shop?.lines.count, 3)
        XCTAssertEqual(fixture.sharedShopCreates, 1)
        XCTAssertEqual(fixture.kinds.filter { $0 == "shop.freeze" }.count, 1)
        XCTAssertEqual(fixture.kinds.filter { $0 == "shop.reopen" }.count, 1)
        XCTAssertEqual(fixture.privateReads, 0)
    }
    func testUnavailableTrackingReadNeverFallsBackToAnOrdinaryRequestApply() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); await shared.applyReviewed()
        let people = try XCTUnwrap(mia.lifecycle); await people.createAdultInvitation()
        let invitation = try XCTUnwrap(people.issued)
        let sam = try await model("sam", fixture: fixture); let join = try XCTUnwrap(sam.lifecycle)
        join.alias = "Sam"; join.invitationCode = invitation.token; join.adultAttestation = true; join.keepLocalPrivate = true
        await join.redeemInvitation()
        sam.item = "Cereal"; sam.quantity = "one box"; await sam.sendRequest()
        let inbox = try XCTUnwrap(mia.shopperInbox); await inbox.load()
        inbox.select(try XCTUnwrap(inbox.requests.first)); inbox.choice = .add; inbox.price = "3.49"
        await inbox.review(); inbox.acceptOverage = true
        fixture.trackingReadUnavailable = true; await inbox.apply()
        XCTAssertEqual(inbox.shop?.lines.count, 1)
        XCTAssertFalse(fixture.kinds.contains("request.apply"))
        XCTAssertNil(inbox.trackingRequest); XCTAssertNil(inbox.pending)
        XCTAssertNil(inbox.preview); XCTAssertNotNil(inbox.notice)
    }
    func testNewSharedShopStartsWithoutThePreviousStoresReviewOrPrices() async throws {
        let fixture = SharedFlowService()
        let adult = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        let previousID = try XCTUnwrap(shared.shop?.shopId)

        fixture.canSelectShop = true
        fixture.storeBasisRevision = 7
        await shared.load()
        shared.beginEditing()
        shared.reviewDraft()
        XCTAssertEqual(shared.review?.candidate?.reviewedStoreBasisRevision, 7)
        shared.cancelEditing()

        shared.beginAnotherShop()
        XCTAssertTrue(shared.draft.lines.isEmpty)
        XCTAssertTrue(shared.draft.cap.isEmpty)
        shared.draft.lines = [.init(item: "Coffee at the market", price: "3.10")]
        shared.reviewDraft()
        let review = try XCTUnwrap(shared.review)
        XCTAssertEqual(review.kind, "shop.create")
        XCTAssertNotEqual(review.shopID, previousID)
        let candidate = try XCTUnwrap(review.candidate)
        XCTAssertNil(try candidate.commandBody()["reviewedStoreBasisRevision"])
        XCTAssertEqual(candidate.lines.map(\.unitPriceMinor), [310])
        shared.acknowledged = true
        await shared.applyReviewed()
        XCTAssertEqual(fixture.sharedShopCreates, 2)
        XCTAssertEqual(shared.shop?.shopId, review.shopID)
    }
    func testFallbackLibrarySurvivesBillingOutageAndClosesOnShopperTransferDuringSeatCheck() async throws {
        let fixture = SharedFlowService()
        let adult = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        let id = try XCTUnwrap(fixture.shopID.flatMap(UUID.init(uuidString:)))
        let service = try XCTUnwrap(adult.service)
        let library = SharedFallbackModel(shopID: id, service: service, store: adult.fallbackPendingStore, authorized: { true })
        fixture.fallbackBillingUnavailable = true
        await library.load()
        XCTAssertEqual(library.library?.shopId, id)
        XCTAssertFalse(library.canSuggest)
        XCTAssertEqual(library.notice, fallbackText("Couldn’t check membership. Refresh to try again."))
        fixture.transferAfterLibraryRead = true
        await library.load()
        XCTAssertNil(library.library)
        XCTAssertNil(library.pending)
        XCTAssertFalse(library.canSuggest)
    }
    func testShopDraftRequiresExplicitReviewAndEditsInvalidateIt() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        shared.beginEditing(); XCTAssertTrue(shared.draft.lines.isEmpty); XCTAssertFalse(shared.draft.complete)
        XCTAssertEqual(shared.draft.tax, ""); XCTAssertEqual(shared.draft.fee, "")
        await shared.applyReviewed(); XCTAssertEqual(fixture.sharedShopCreates, 0)
        enterShop(shared); shared.acknowledged = false; await shared.applyReviewed(); XCTAssertEqual(fixture.sharedShopCreates, 0)
        shared.acknowledged = true; shared.draft.lines[0].price = "39.20"
        XCTAssertNil(shared.review); XCTAssertFalse(shared.acknowledged)
        await shared.applyReviewed(); XCTAssertEqual(fixture.sharedShopCreates, 0)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.lines.first?.unitPriceMinor, 3920)
        shared.beginEditing(); shared.draft.tax = "1.25"; shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.quote.taxesMinor, 125); XCTAssertEqual(shared.shop?.shopRevision, 2)
    }
    func testPartialTrackedMealEditUsesTrackingReviewInsteadOfLegacyGraphOrDirectApply() async throws {
        let fixture = SharedFlowService(), mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); await shared.applyReviewed()
        let (page, template, _, edit, _) = try TrackingPartialMealFixture.setup(TrackingPartialMealFixture.fixture())
        fixture.revision = page.shopRevision
        fixture.lines = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template.lines)) as! [[String: Any]]
        var raw: Any = try TrackingPartialMealFixture.fixture()["page"]!
        for (path, value): (String, Any) in [("shopId", fixture.shopID!), ("authorityEpoch", 1), ("state.authorityEpoch", 1),
            ("state.graph.shopId", fixture.shopID!), ("state.graph.householdId", fixture.household)] {
            raw = TrackingFlowFixture.edit(raw, path, value)
        }
        fixture.trackingPageOverride = raw as? [String: Any]
        await shared.load(); shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: edit.occurrenceId.uuid, meal: edit.meal)
        let commands = fixture.kinds.count
        await shared.reviewEditor()
        XCTAssertNil(shared.review); XCTAssertNil(shared.foodEditor)
        let editor = try XCTUnwrap(shared.trackingEditor)
        XCTAssertEqual(editor.mealEdit?.occurrenceId, edit.occurrenceId)
        XCTAssertEqual(editor.mealEdit?.meal, edit.meal)
        XCTAssertEqual(fixture.kinds.count, commands); XCTAssertNil(shared.pending)
    }
    func testSharedMealReviewBindsPacksDateAndRevisionAndRejectsAStaleEditor() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        let occurrenceID = UUID()
        let meal = SharedMeal(title: "Chickpea dinner", day: "2026-11-05", kind: "dinner", portions: 3, protected: false)
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: occurrenceID, meal: meal)
        shared.draft.lines[0].packs = 2
        shared.reviewDraft()
        XCTAssertEqual(shared.review?.mealEdit?.meal, meal)
        XCTAssertTrue(fixture.meals.isEmpty)
        shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.shopRevision, 2)
        XCTAssertEqual(shared.shop?.meals?.first?.meal, meal)
        XCTAssertEqual(shared.shop?.lines.first?.packs, 2)
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: occurrenceID, meal: nil)
        shared.reviewDraft()
        fixture.revision += 1
        await shared.load()
        XCTAssertNil(shared.review); XCTAssertFalse(shared.editing)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(fixture.meals.count, 1)
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: occurrenceID, meal: nil)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.meals?.count, 0)
        XCTAssertEqual(shared.shop?.lines.first?.packs, 2)
    }
    func testLostCreateResponseCanRecoverOriginalOperationWithoutSecondShop() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); fixture.loseCreateResponse = true
        await shared.applyReviewed()
        let operation = try XCTUnwrap(shared.pending); XCTAssertEqual(shared.delivery, .waiting)
        fixture.loseCreateResponse = false
        let scope = try XCTUnwrap(mia.projection)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SharedFlowURLProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config))
        let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://identity.test")!, publishableKey: "sb_publishable_test"), vault: SharedFlowVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "mia@example.test", code: "123456")
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://household.test")!), auth: auth, deviceVault: SharedFlowVault(), transport: transport)
        let fresh = try await service.enroll(householdID: scope.household.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("retry.json")
        let outbox = OperationOutbox(url: url); try await outbox.append(operation)
        let restored = HouseholdShopModel(scope: fresh, service: service, outbox: outbox, onConfirmed: {}, onAccessEnded: {})
        await restored.load(); await restored.retry()
        XCTAssertNil(restored.pending); XCTAssertEqual(restored.shop?.lines.count, 1)
        XCTAssertEqual(fixture.sharedShopCreates, 1)
        let creates = fixture.commandBodies.filter { $0.kind == "shop.create" }.map(\.bytes)
        XCTAssertEqual(creates, [operation.bytes, operation.bytes])
    }
    func testConfirmedCreationSurvivesReadFailureAndCannotCreateAnotherShop() async throws {
        for status in [503, 403] {
            let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
            let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); fixture.readFailureAfterCreate = status
            await shared.applyReviewed()
            XCTAssertNil(shared.pending); XCTAssertFalse(shared.canCreate); XCTAssertFalse(shared.canManage)
            if status == 403 { XCTAssertNil(mia.sharedShop); XCTAssertNil(shared.shop); XCTAssertTrue(mia.locked) }
            else {
                if case .confirmed = shared.delivery {} else { XCTFail("Confirmed receipt was lost") }
                fixture.readFailureAfterCreate = nil; await shared.load()
                XCTAssertEqual(shared.shop?.lines.count, 1); XCTAssertFalse(shared.canCreate); XCTAssertTrue(shared.canManage)
            }
        }
    }
    func testFinancialEvidenceStaysWithTheAssignedShopperAndClearsOnTransfer() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        await shared.load()
        XCTAssertNotNil(shared.lastShopSync)
        await shared.loadFinancialEntries()
        let entries = try XCTUnwrap(shared.financialEntries)
        XCTAssertEqual(entries.map(\.kind), [.paymentHold])
        XCTAssertEqual(entries.first?.amountMinor, 3200)
        XCTAssertEqual(entries.first?.sourceText, "Hold on the entered receipt")
        let service = try XCTUnwrap(mia.service)
        let reviewed = try XCTUnwrap(shared.financialRecord)
        let entry = ShopperFinancialEntry(kind: .postedCharge, amountMinor: 3720,
                                         occurredAt: Date().ISO8601Format(), sourceText: "Net receipt")
        let priorIntent = try await service.prepareFinancial(.append(entry), reviewed: reviewed)
        fixture.shopperTransferred = true
        await mia.refresh()
        XCTAssertNil(shared.financialEntries)
        do {
            try await service.executeFinancial(priorIntent)
            XCTFail("Former shopper could submit financial evidence")
        } catch ClientError.accessEnded {}
        XCTAssertNil(shared.lastShopSync)
        XCTAssertFalse(shared.canManage)
    }

    func testChangedShopperAuthorityClearsPrivateViewsBeforeRequestListFailure() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        XCTAssertTrue(shared.canManage)
        mia.item = "Old shop draft"
        shared.beginEditing()
        XCTAssertFalse(shared.draft.lines.isEmpty)
        fixture.shopperTransferred = true
        fixture.ownRequestsUnavailable = true
        await mia.refresh()
        XCTAssertEqual(mia.projection?.role, "organizer")
        XCTAssertNil(mia.shopperInbox)
        XCTAssertFalse(shared.canManage)
        XCTAssertNil(shared.shop)
        XCTAssertTrue(mia.item.isEmpty)
        XCTAssertTrue(shared.draft.lines.isEmpty)
    }

    func testOrganizerReviewsTransferAndLosesShopperBudgetAfterConfirmation() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        let id = try XCTUnwrap(fixture.shopID.flatMap(UUID.init(uuidString:)))
        let service = try XCTUnwrap(mia.service)
        let authority = try await service.shopperAssignment(shopID: id)
        let next = try XCTUnwrap(authority.adults.first(where: { $0.id != authority.shopperId }))
        shared.reviewTransfer(authority, to: next.id)
        XCTAssertEqual(shared.review?.transfer?.toLabel, "Alex")
        await shared.applyReviewed(); XCTAssertFalse(fixture.shopperTransferred)
        shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertTrue(fixture.shopperTransferred); XCTAssertFalse(shared.canManage)
        XCTAssertNil(shared.shop); XCTAssertNil(mia.shopperInbox)
        XCTAssertEqual(fixture.kinds.filter { $0 == "shop.transferAuthority" }.count, 1)
    }
    func testLockClearsSharedBudgetAndPreventsRetainedModelFromPublishing() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); await shared.applyReviewed()
        shared.beginEditing(); shared.reviewDraft(); shared.acknowledged = true
        mia.lock()
        XCTAssertNil(mia.sharedShop); XCTAssertNil(shared.shop); XCTAssertNil(shared.review); XCTAssertTrue(shared.draft.lines.isEmpty)
        await shared.applyReviewed(); XCTAssertEqual(fixture.kinds.filter { $0 == "shop.patch" }.count, 0)
    }
}

/// HTTP contract fixture: starts with no household or shop. PostgreSQL acceptance is run separately by the service owner.
private final class SharedFlowService {
    let household = UUID().uuidString.lowercased(), miaID = UUID().uuidString.lowercased(), samID = UUID().uuidString.lowercased()
    var householdCreates = 0, sharedShopCreates = 0, privateReads = 0
    var meals: [[String: Any]] = []
    var joined = Set<String>(), shopID: String?, revision = 0, phase = "draft"
    var quote: [String: Any] = [:], lines: [[String: Any]] = [], requests: [[String: Any]] = []
    var kinds: [String] = [], commandBodies: [(kind: String, bytes: Data)] = []
    var receipts: [String: [String: Any]] = [:], previews: [String: [String: Any]] = [:]
    var trackingReadUnavailable = false
    var trackingPageOverride: [String: Any]?
    var loseCreateResponse = false
    var shopperTransferred = false
    var fallbackBillingUnavailable = false
    var canSelectShop = false
    var storeBasisRevision: Int?
    var transferAfterLibraryRead = false
    var ownRequestsUnavailable = false
    var readFailureAfterCreate: Int?
    var placedRevision: Int?
    var confirmedOrderFailure: (Int, String)?
    var deliverySources: [[String: Any]] = []
    var supplyRevision = 0
    var loseDeliveryResponse = false
    var rejectExcludedMatch = false, pantryAvailable = false
    var pantryLots: [[String: Any]] = []
    func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data("{}".utf8) }
        stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; bytes.append(buffer, count: size) }
        return bytes
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path, actor = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? "mia"
        let input = try body(request); let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        func ok(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try data(value)) }
        if path == "/auth/v1/verify" {
            let name = (json["email"] as! String).components(separatedBy: "@")[0]
            return try ok(["access_token":name,"refresh_token":name+"-refresh","expires_in":3600,"user":["id":name,"email_confirmed_at":"date"]])
        }
        if path == "/auth/v1/user" { return try ok(["id":actor,"email_confirmed_at":"date"]) }
        if path == "/v1/households" { householdCreates += 1; joined.insert(actor); return try ok(["householdId":household,"memberId":miaID,"role":"organizer"],201) }
        if path == "/v1/me/workspaces" { return try ok(["workspaces":joined.contains(actor) ? [["householdId":household,"label":"Our home","role":actor == "mia" ? "organizer" : "contributor"]] : []]) }
        if path == "/v1/invites/redeem" { joined.insert(actor); return try ok(["householdId":household,"memberId":samID,"role":"contributor"]) }
        if path.hasSuffix("/devices") { return try ok(["deviceId":actor+"-device","deviceToken":actor+"-device-token"],201) }
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), actor+"-device-token")
        if path.hasSuffix("/bootstrap") {
            if shopID != nil, let status = readFailureAfterCreate { return try ok(["error":["code":"access_ended","correlationId":"test"]],status) }
            let shopper = actor == "mia" && shopID != nil && !shopperTransferred
            let evidenceCapabilities = placedRevision == nil ? [] : ["confirmed_order", "delivery_evidence"] + (pantryAvailable ? ["pantry_lots"] : [])
            return try ok(["household":["id":household,"label":"Our home"],"memberId":actor == "mia" ? miaID : samID,
                "role":shopper ? "shopper" : actor == "mia" ? "organizer" : "contributor", "canSelectShop":canSelectShop, "shopId":shopID as Any? ?? NSNull(),"enrolled":true,"queueConsent":false,
                "capabilities":["own_requests"] + (actor == "mia" ? ["household_admin"] : []) + (shopper ? ["shopper_inbox","request_preview","shopper_commands","accepted_fallbacks"] + evidenceCapabilities : [])])
        }
        if path.hasSuffix("/accepted-fallbacks"), let shopID {
            if transferAfterLibraryRead { shopperTransferred = true }
            return try ok(["shopId":shopID, "shopRevision":revision, "authorityEpoch":1, "registryRevision":0, "candidates":[], "nextCursor":NSNull()])
        }
        if path.hasSuffix("/entitlements"), fallbackBillingUnavailable { return try ok(["error":["code":"service_unavailable"]],503) }
        if path.hasSuffix("/replay-windows") { return try ok(["id":UUID().uuidString.lowercased(),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/invites") { return try ok(["inviteId":UUID().uuidString.lowercased(),"token":household+"."+String(repeating:"a",count:43),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/requests/mine"), ownRequestsUnavailable { return try ok(["error":["code":"unavailable"]],503) }
        if path.hasSuffix("/requests/mine") { return try ok(["requests":actor == "sam" ? requests : [],"nextCursor":NSNull()]) }
        if path.hasSuffix("/shopper-assignment"), let shopID {
            return try ok(["shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"phase":phase,"shopperId":miaID,
                "adults":[["id":miaID,"label":"Mia"],["id":samID,"label":"Alex"]]])
        }
        if path.hasSuffix("/financial-evidence"), let shopID {
            return try ok(["shopId": shopID, "sourceVersion": ["shopRevision": revision, "authorityEpoch": 1, "financialRevision": 1],
                "evidenceSource": "shopper_reported", "entries": [["id": UUID().uuidString, "evidenceKey": UUID().uuidString, "kind": "paymentHold", "amountMinor": 3200,
                "currency": "USD", "occurredAt": "2026-01-01T12:00:00.000Z", "sourceText": "Hold on the entered receipt"]], "nextCursor": NSNull()])
        }
        if path.hasSuffix("/inbox") { return try ok(["requests":requests.map { $0.merging(["authorAlias":"Sam"]) { _, new in new } },"nextCursor":NSNull()]) }
        if path.hasSuffix("/delivery-evidence"), let shopID, let placedRevision {
            return try ok(["shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"placedRevision":placedRevision,
                "supplyRevision":supplyRevision,"coverageAvailable":false,"reservationsAvailable":false,"meals":meals,
                "lines":lines.map { ["lineId":$0["lineId"]!,"name":$0["originalItem"]!,"packs":$0["packs"]!] },
                "sources":deliverySources,"nextCursor":NSNull()])
        }
        if path.hasSuffix("/pantry-lots"), let shopID, let placedRevision {
            return try ok(["shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"placedRevision":placedRevision,
                "supplyRevision":supplyRevision,"pantryRevision":0,"asOf":Date().ISO8601Format(),"lots":pantryLots,"nextCursor":NSNull()])
        }
        if path.hasSuffix("/confirmed-order"), let shopID, let placedRevision {
            if let (status, code) = confirmedOrderFailure { return try ok(["error":["code":code,"correlationId":"test"]],status) }
            return try ok(["shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"placedRevision":placedRevision,
                "asOf":Date().ISO8601Format(),"original":["lines":lines,"quote":quote,"snapshotCreatedAt":"2026-01-01T00:00:00Z"],
                "current":["lines":lines,"amendmentId":NSNull()],"amendments":[]])
        }
        if request.httpMethod == "GET", let shopID, path.hasSuffix("/shops/" + shopID + "/demand/tracking") {
            if trackingReadUnavailable { return try ok(["error":["code":"service_unavailable"]],503) }
            if let trackingPageOverride { return try ok(trackingPageOverride) }
            let ids = lines.map { $0["lineId"] as! String }
            let basket = lines.map { ["id": $0["lineId"]!, "name": $0["originalItem"]!, "packs": $0["packs"]!,
                "priceMinor": $0["unitPriceMinor"] ?? NSNull(), "feeEligible": $0["feeEligible"]!] }
            let total = lines.reduce(0) { $0 + ($1["packs"] as! Int) * ($1["unitPriceMinor"] as? Int ?? 0) }
            let budget: [String: Any] = ["currency":"USD","totalMinor":total,"overCapMinor":max(0,total-3800),
                "headroomMinor":3800-total,"status":total>3800 ? "overCap":"withinCap","scope":"wholeCheckout",
                "missing":[],"lowerBoundMinor":total,"upperBoundMinor":total,"wholeCheckoutWithinCap":total<=3800]
            let graph: [String: Any] = ["schemaVersion":1,"conversionTableVersion":"us-customary-metric-v1",
                "householdId":household,"shopId":shopID,"revision":0,"lines":[],"contributions":[],"edges":[],"usedIds":[]]
            let state: [String: Any] = ["schemaVersion":2,"authorityEpoch":1,"privacyRevision":0,
                "quoteDigest":String(repeating:"a",count:64),"graph":graph,"basket":basket,"catalog":[],
                "bindings":[],"unbound":[],"legacyLineIds":ids,"packReviews":[]]
            let coverage: [String: Any] = ["status":ids.isEmpty ? "tracked":"partial","trackedSubtotals":[],
                "completeFoodCoverage":false,"unboundFactIds":[],"untrackedBasketIds":ids,
                "protectedUnboundFactIds":[],"allocatableUnboundFactIds":[]]
            return try ok(["schemaVersion":2,"shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"status":"legacy",
                "state":state,"projection":NSNull(),"basisDigest":String(repeating:"b",count:64),
                "checkout":budget,"coverage":coverage,"freezeReview":NSNull()])
        }
        if request.httpMethod == "GET", let shopID, path.hasSuffix("/shops/" + shopID + "/demand") {
            return try ok(["schemaVersion":1,"shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"status":"legacy","graph":NSNull(),"totals":[]])
        }
        if path.contains("/shops/"), request.httpMethod == "GET" { return try ok(["shopId":shopID!,"shopRevision":revision,"authorityEpoch":1,"phase":phase,"quote":quote,"lines":lines,"meals":meals,"storeBasisRevision":storeBasisRevision as Any? ?? NSNull(),"frozenRevision":phase == "frozen" ? revision : NSNull(),"placedRevision":placedRevision as Any? ?? NSNull()]) }
        if path.hasSuffix("/previews") {
            let id = UUID().uuidString.lowercased(); previews[id] = json
            let total = lines.reduce(0) { $0 + ($1["packs"] as! Int) * ($1["unitPriceMinor"] as? Int ?? 0) }
            let decision = json["decision"] as! [String: Any], line = decision["line"] as! [String: Any]
            let after = total + (line["unitPriceMinor"] as? Int ?? 0) * (line["packs"] as! Int)
            func budget(_ amount: Int) -> [String: Any] { ["currency":"USD","totalMinor":amount,"overCapMinor":max(0,amount-3800),"headroomMinor":3800-amount,"status":amount>3800 ? "overCap":"withinCap","scope":"wholeCheckout","missing":[],"lowerBoundMinor":amount,"upperBoundMinor":amount,"wholeCheckoutWithinCap":amount<=3800] }
            let base = json["base"] as! [String: Any]
            return try ok(["previewId":id,"expiresAt":"2099-01-01T00:00:00Z","shopRevision":revision,"authorityEpoch":1,"requestRevision":base["requestRevision"]!,"choice":"add","before":budget(total),"after":budget(after),"changeMinor":after-total,"requiresOverageAcceptance":after>3800,"requiresUnknownAcceptance":false])
        }
        if path.hasSuffix("/commands") {
            let kind = json["kind"] as! String, key = json["clientKey"] as! String, body = json["body"] as! [String: Any]
            commandBodies.append((kind,input))
            if let prior = receipts[key] { return try ok(prior) }
            kinds.append(kind)
            if rejectExcludedMatch, ["delivery.match", "pantry.match"].contains(kind), body["matched"] as? Bool == true {
                return try ok(["error":["code":"match_exclusion_conflict","correlationId":"test"]],409)
            }
            if kind.hasPrefix("delivery.") {
                let operation = UUID().uuidString.lowercased()
                guard body["supplyRevision"] as? Int == supplyRevision else { return try ok(["error":["code":"stale_supply"]],409) }
                let sourceID = kind == "delivery.register" ? operation : body["sourceId"] as! String
                if kind == "delivery.register" {
                    deliverySources.append(["sourceId":sourceID,"foodId":sourceID,"lineId":body["lineId"]!,"segmentKey":body["segmentKey"]!,
                        "foodName":body["foodName"]!,"exclusionTags":body["exclusionTags"]!,"matches":[],"reservations":[],"arrival":NSNull(),"usable":NSNull(),"confirmed":NSNull()])
                } else if let index = deliverySources.firstIndex(where: { $0["sourceId"] as? String == sourceID }) {
                    if kind == "delivery.arrival" { deliverySources[index]["arrival"] = body; deliverySources[index]["confirmed"] = NSNull() }
                    if kind == "delivery.usable" {
                        deliverySources[index]["usable"] = body
                        deliverySources[index]["confirmed"] = ["sourceId":sourceID,"foodId":sourceID,"quantity":body["usable"]!,
                            "arrivalId":body["arrivalObservationId"]!,"usableId":body["observationId"]!]
                    }
                }
                supplyRevision += 1
                let receipt: [String: Any] = ["operationId":operation,"kind":kind,"shopId":shopID!,"shopRevision":revision,
                    "authorityEpoch":1,"disposition":"recorded","sourceId":sourceID,"supplyRevision":supplyRevision]
                receipts[key] = receipt
                if loseDeliveryResponse { throw URLError(.networkConnectionLost) }
                return try ok(receipt)
            }
            if kind == "shop.create" { sharedShopCreates += 1; shopID = json["shopId"] as? String; revision = 1; quote = body["quote"] as! [String:Any]; lines = body["lines"] as! [[String:Any]] }
            if kind == "shop.patch" { quote = body["quote"] as! [String:Any]; lines = body["lines"] as! [[String:Any]]; revision += 1 }
            if kind == "shop.patch", let edit = body["mealEdit"] as? [String:Any], let id = edit["occurrenceId"] as? String {
                meals.removeAll { $0["occurrenceId"] as? String == id }
                if let meal = edit["meal"] as? [String:Any] { meals.append(["occurrenceId": id,"revision":revision,"meal":meal]) }
            }
            if kind == "shop.transferAuthority" {
                guard body["newShopperId"] as? String == samID else { throw URLError(.badServerResponse) }
                shopperTransferred = true
            }
            if kind == "shop.freeze" { phase = "frozen"; revision += 1 }
            if kind == "shop.reopen" { phase = "draft"; revision += 1 }
            if kind == "request.send" {
                let value: [String:Any] = ["requestId":UUID().uuidString.lowercased(),"shopId":shopID!,"revision":1,"originalItem":body["originalItem"]!,"ownQuantity":body["ownQuantity"]!,"authoredAt":body["authoredAt"]!,"receivedAt":"2026-11-03T00:00:00Z","route":phase == "draft" ? (body["route"] ?? "current") : "next","status":"pending","ownActionAllowed":true,"clarification":NSNull(),"followupTo":NSNull()]
                requests.append(value); let receipt: [String:Any] = ["operationId":UUID().uuidString,"kind":kind,"request":value]; receipts[key] = receipt; return try ok(receipt)
            }
            if kind == "request.apply" {
                let preview = previews[body["previewId"] as! String]!, decision = preview["decision"] as! [String:Any]
                lines.append(decision["line"] as! [String:Any]); revision += 1
                if let index = requests.firstIndex(where: { $0["requestId"] as? String == body["requestId"] as? String }) { requests[index]["status"] = "added"; requests[index]["ownActionAllowed"] = false; requests[index]["revision"] = 2 }
            }
            let receipt: [String:Any] = ["operationId":UUID().uuidString,"kind":kind,"shopId":shopID!,"shopRevision":revision,"authorityEpoch":1,"disposition":"confirmed"]
            receipts[key] = receipt
            if kind == "shop.create", loseCreateResponse { throw URLError(.networkConnectionLost) }
            return try ok(receipt)
        }
        privateReads += 1; throw URLError(.unsupportedURL)
    }
}
private final class SharedFlowVault: RefreshTokenVault, @unchecked Sendable {
    var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
private final class SharedFlowHeldRead: @unchecked Sendable {
    private let lock = NSLock()
    private let pathSuffix: String
    private let arrived: () -> Void
    private var held = false
    private var resume: (() -> Void)?
    init(pathSuffix: String, arrived: @escaping () -> Void) { self.pathSuffix = pathSuffix; self.arrived = arrived }
    func capture(_ request: URLRequest, resume: @escaping () -> Void) -> Bool {
        lock.lock()
        guard !held, request.url?.path.hasSuffix(pathSuffix) == true else { lock.unlock(); return false }
        held = true; self.resume = resume; lock.unlock(); arrived(); return true
    }
    func release() { lock.lock(); let callback = resume; resume = nil; lock.unlock(); callback?() }
}
private final class SharedFlowURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static var heldRead: SharedFlowHeldRead?
    override func startLoading() {
        if Self.heldRead?.capture(request, resume: { [weak self] in self?.deliver() }) == true { return }
        deliver()
    }
    private func deliver() {
        do { let (code,data) = try Self.handler(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

@MainActor final class HouseholdHelperReviewFlowTests: XCTestCase {
    private func fixture(store: HelperReviewMemoryStore = .init()) async -> (HouseholdHelperReviewModel, HelperReviewFakeService, HelperReviewMemoryStore, HelperReviewScopeBox) {
        let box = HelperReviewScopeBox(), service = HelperReviewFakeService(store: store)
        let model = HouseholdHelperReviewModel(grantID: HelperReviewData.grant, service: service, store: store,
            runtime: { box.value }, accessEnded: { box.value = nil })
        await model.load(); return (model, service, store, box)
    }
    func testExplicitReviewAndApprovalPersistBeforeSending() async throws {
        let (model, service, store, _) = await fixture()
        await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        model.review(decision: .replace, projection: service.current.projection)
        await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        model.approved = true; await model.apply()
        XCTAssertEqual(service.sent.count, 1); XCTAssertTrue(service.wasPersistedBeforeSend)
        XCTAssertNotNil(model.receipt); XCTAssertNil(model.pending)
        let saved = try await store.read(); XCTAssertTrue(saved.reviewActions?.isEmpty ?? true)
    }
    func testUncertainResultRestoresAndReplaysOriginalBytesAfterRevisionChanges() async throws {
        let (model, service, store, box) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.failDelivery = true; await model.apply()
        let original = try XCTUnwrap(model.pending); XCTAssertNil(model.receipt)
        service.current = HelperReviewData.current(revision: 2); service.failDelivery = false
        let restored = HouseholdHelperReviewModel(grantID: HelperReviewData.grant, service: service, store: store,
            runtime: { box.value }, accessEnded: {})
        await restored.load(); XCTAssertEqual(restored.pending, original); XCTAssertFalse(restored.canReview)
        XCTAssertEqual(service.sent.count, 1) // Loading never sends.
        await restored.retryAndReconcile()
        XCTAssertEqual(service.sent, [original, original]); XCTAssertEqual(service.preparations, 1)
        XCTAssertNotNil(restored.receipt); XCTAssertNil(restored.pending)
    }
    func testPersistenceFailureNeverSends() async throws {
        let store = HelperReviewMemoryStore(failSave: true)
        let (model, service, _, _) = await fixture(store: store)
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        await model.apply(); XCTAssertTrue(service.sent.isEmpty); XCTAssertNil(model.receipt)
    }
    func testConfirmedReceiptCleanupRetryDoesNotSendAgain() async throws {
        let store = HelperReviewMemoryStore(failRemove: true)
        let (model, service, _, _) = await fixture(store: store)
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        await model.apply(); XCTAssertNotNil(model.receipt); XCTAssertNotNil(model.pending)
        await store.allowRemoval(); await model.retryAndReconcile()
        XCTAssertEqual(service.sent.count, 1); XCTAssertNil(model.pending)
    }
    func testScopeChangeDuringPreparationCannotPersistOrSendAndClearsVisibleData() async throws {
        let (model, service, store, box) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.beforePrepare = { box.value = nil }
        await model.apply(); model.enforceRuntime()
        XCTAssertTrue(service.sent.isEmpty); XCTAssertNil(model.current); XCTAssertNil(model.reviewed)
        let saved = try await store.read(); XCTAssertNil(saved.reviewActions)
    }
    func testPurgeAfterReviewRejectsLatePrivateSave() async throws {
        let (model, service, store, _) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.beforePrepare = { await store.purge() }
        await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        let saved = try await store.read(); XCTAssertNil(saved.reviewActions)
    }
    func testChangedDraftOrStaleServerSnapshotCannotApplyOldApproval() async throws {
        let (model, service, _, _) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        model.cancelReview(); await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.current = HelperReviewData.current(revision: 2)
        await model.apply(); XCTAssertTrue(service.sent.isEmpty); XCTAssertNil(model.reviewed); XCTAssertFalse(model.approved)
    }
    func testClearingUncertainRetryNeedsFreshAuthorizedStatus() async throws {
        let (model, service, store, _) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.failDelivery = true; await model.apply(); XCTAssertNotNil(model.pending)
        service.failRead = true; await model.clearRetryAfterStatusReview()
        let saved = try await store.read(); XCTAssertEqual(saved.reviewActions?.count, 1)
        XCTAssertEqual(service.sent.count, 1)
    }
}

@MainActor private final class HelperReviewScopeBox {
    var value: HouseholdHelperReviewScope? = .init(generation: UUID(), subject: "reviewer", householdID: HelperReviewData.household,
        memberID: HelperReviewData.member, shopID: HelperReviewData.shop)
}
private actor HelperReviewMemoryStore: HelperReviewPersisting {
    var state = LifecyclePendingState(); var epoch = UUID()
    let failSave: Bool; var failRemove: Bool
    init(failSave: Bool = false, failRemove: Bool = false) { self.failSave = failSave; self.failRemove = failRemove }
    func read() throws -> LifecyclePendingState { state }
    func reviewEpoch() -> UUID { epoch }
    func saveReviewAction(_ intent: HelperReviewIntent, expectedEpoch: UUID) throws {
        guard expectedEpoch == epoch else { throw ClientError.cancelled }
        if failSave { throw ClientError.transport }; state.reviewActions = [intent]
    }
    func removeReviewAction(id: String) throws {
        if failRemove { throw ClientError.transport }; state.reviewActions?.removeAll { $0.id == id }
    }
    func allowRemoval() { failRemove = false }
    func purge() { epoch = UUID(); state = .init() }
}
@MainActor private final class HelperReviewFakeService: HelperReviewServing {
    var current = HelperReviewData.current()
    let store: HelperReviewMemoryStore
    var beforePrepare: (() async -> Void)?
    var failDelivery = false; var failRead = false
    var sent: [HelperReviewIntent] = []; var preparations = 0; var wasPersistedBeforeSend = false
    init(store: HelperReviewMemoryStore) { self.store = store }
    func managedHelperProjection(grantID: String, shopID: String) async throws -> ManagedHelperProjection {
        if failRead { throw ClientError.transport }; return current
    }
    func managedHelperProposal(grantID: String, proposalID: String, shopID: String) async throws -> HelperProposal { throw ClientError.configuration }
    func prepareHelperReview(current: ManagedHelperProjection, proposal: HelperProposal?, decision: HelperReviewDecision, projection: HelperProjection?) async throws -> HelperReviewIntent {
        preparations += 1
        guard current == self.current else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        await beforePrepare?()
        return try HelperReviewData.intent(current: current, projection: XCTUnwrap(projection))
    }
    func reconcileHelperReview(_ intent: HelperReviewIntent) async throws -> HelperReviewReceipt {
        let saved = try await store.read(); wasPersistedBeforeSend = saved.reviewActions?.contains(intent) == true
        sent.append(intent)
        if failDelivery { throw ClientError.transport }
        return HelperReviewData.decode(["mutationId": UUID().uuidString, "grantId": intent.grantID, "baseRevision": intent.baseRevision,
            "revision": intent.baseRevision + 1, "status": "replaced", "asOf": "2026-11-03T00:00:00Z"])
    }
}
private enum HelperReviewData {
    static let household = "00000000-0000-4000-8000-000000000001", member = "00000000-0000-4000-8000-000000000002"
    static let grant = "00000000-0000-4000-8000-000000000003", shop = "00000000-0000-4000-8000-000000000004"
    static func decode<T: Decodable>(_ value: [String: Any]) -> T { try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
    static func current(revision: Int = 1) -> ManagedHelperProjection {
        decode(["grantId": grant, "shopId": shop, "revision": revision, "asOf": "2026-11-03T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z", "mode": "edit",
            "projection": ["shopLabel": "Cook", "language": "en", "items": [["label": "Rice", "amount": NSNull(), "unit": NSNull(), "action": "Warm rice"]]]])
    }
    static func intent(current: ManagedHelperProjection, projection: HelperProjection) throws -> HelperReviewIntent {
        let id = UUID().uuidString.lowercased(), value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection))
        let bytes = try JSONSerialization.data(withJSONObject: ["clientKey": id, "baseRevision": current.revision, "projection": value], options: [.sortedKeys])
        return decode(["id": id, "subject": "reviewer", "householdID": household, "memberID": member, "deviceID": "test-device", "grantID": grant, "shopID": shop,
            "baseRevision": current.revision, "decision": "replace", "projection": value, "bytes": bytes.base64EncodedString()])
    }
}
