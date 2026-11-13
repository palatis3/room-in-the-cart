import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class HistoryFlowTests: XCTestCase {
    private let household = "10000000-0000-4000-8000-000000000001"
    private let member = "10000000-0000-4000-8000-000000000002"
    private let shop = "10000000-0000-4000-8000-000000000003"

    func testNewBudgetPeriodKeepsLocalClockTimeAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        for (start, end) in [
            ("2026-03-01T04:30:00Z", "2026-03-15T03:30:00Z"),
            ("2026-10-24T04:30:00Z", "2026-11-07T05:30:00Z")
        ] {
            let startDate = try XCTUnwrap(HistoryDate.date(start))
            let endDate = try XCTUnwrap(HistoryDate.date(end))
            var draft = HistoryPeriodDraft(start: startDate, calendar: calendar)
            draft.title = "Two-week grocery budget"
            draft.budget = "120"
            let saved = try draft.dto()
            let reopened = HistoryPeriodDraft(.init(periodId: saved.id, revision: 1, period: saved))
            XCTAssertEqual(reopened.timeZoneID, calendar.timeZone.identifier)
            XCTAssertEqual(reopened.startsAt, startDate)
            XCTAssertEqual(reopened.endsAt, endDate)
        }
    }

    private func setup() async throws -> (HistoryFeatureModel, HistoryFixtureService, HistoryFixtureStore, HistoryScopeBox) {
        let service = try HistoryFixtureService()
        let store = HistoryFixtureStore()
        let box = HistoryScopeBox(.init(generation: UUID(), subject: "adult", householdID: household, memberID: member, currentShopID: shop, authorityStamp: "shopper"))
        let model = HistoryFeatureModel(service: service, store: store, runtime: { box.value })
        await model.load(); XCTAssertTrue(model.authorized); XCTAssertTrue(model.canEdit)
        return (model, service, store, box)
    }
    private func enterObservation(_ model: HistoryFeatureModel) {
        model.beginObservation(); model.observationDraft.itemName = "Oats"; model.observationDraft.packLabel = "12 oz"
        model.observationDraft.store = "Store"; model.observationDraft.branch = "North"; model.observationDraft.sourceText = "Shelf label"
        model.observationDraft.exactPrice = "3.49"; model.reviewObservation()
    }
    func testExplicitReviewApprovalAndPersistenceBeforeNetwork() async throws {
        let (model, service, store, _) = try await setup()
        enterObservation(model); await model.applyReviewed(); XCTAssertEqual(service.observationSends.count, 0)
        model.approved = true
        service.beforeObservationSend = { intent in
            let state = await store.read(); XCTAssertEqual(state.pending, [.observation(intent)])
        }
        await model.applyReviewed()
        XCTAssertEqual(service.observationSends.count, 1); XCTAssertNil(model.pending)
        XCTAssertEqual(model.selectedObservation?.price, .exact(minor: 349))
        let saved = await store.read(); XCTAssertEqual(saved.observations.count, 1); XCTAssertTrue(saved.pending.isEmpty)
    }
    func testSavedObservationReferencesUseReadGrantsWithoutAddingWritableShops() async throws {
        let (model, service, store, _) = try await setup()
        let granted = "10000000-0000-4000-8000-000000000004", observation = UUID().uuidString.lowercased()
        await store.addReference(.init(subject: "adult", householdID: household, memberID: member, shopID: granted, observationID: observation))
        service.readablePages[nilKey] = .init(shopIds: [granted], nextCursor: nil)
        await model.load()
        XCTAssertEqual(model.savedObservationIDs, [observation])
        XCTAssertEqual(model.ownedShops.map(\.shopId), [shop])
        XCTAssertFalse(model.ownedShops.contains { $0.shopId == granted })
        service.readablePages[nilKey] = .init(shopIds: [], nextCursor: nil)
        await model.loadReadableShops()
        XCTAssertTrue(model.savedObservationIDs.isEmpty)
        XCTAssertEqual(model.ownedShops.map(\.shopId), [shop])
    }
    func testSavedReferenceAccessPaginationAndRevokedRecordClearVisibleFacts() async throws {
        let (model, service, store, _) = try await setup()
        let granted = "10000000-0000-4000-8000-000000000004", observation = UUID().uuidString.lowercased()
        await store.addReference(.init(subject: "adult", householdID: household, memberID: member, shopID: granted, observationID: observation))
        service.readablePages[nilKey] = .init(shopIds: [shop], nextCursor: shop)
        service.readablePages[shop] = .init(shopIds: [granted], nextCursor: nil)
        await model.load(); XCTAssertTrue(model.savedObservationIDs.isEmpty)
        await model.loadReadableShops(more: true)
        XCTAssertEqual(model.savedObservationIDs, [observation]); XCTAssertNil(model.readableShopCursor)
        service.observationReadError = ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)
        await model.openObservation(observation)
        XCTAssertNil(model.selectedObservation); XCTAssertTrue(model.savedObservationIDs.isEmpty)
    }
    func testBudgetGrantAloneCannotBeginOrReviewPriceObservationAndDoesNotGateFuturePeriodDraft() async throws {
        let (model, service, _, box) = try await setup()
        let granted = "10000000-0000-4000-8000-000000000004", old = try XCTUnwrap(box.value)
        service.ownedSources = []; service.readablePages[nilKey] = .init(shopIds:[granted],nextCursor:nil)
        box.value = .init(generation:old.generation,subject:old.subject,householdID:old.householdID,memberID:old.memberID,currentShopID:granted,authorityStamp:"contributor|store_quotes")
        await model.load(); XCTAssertTrue(model.authorized); XCTAssertTrue(model.canEdit)
        XCTAssertFalse(model.canBeginObservation); XCTAssertFalse(model.canReviewObservation); XCTAssertEqual(model.observationDraft.shopID,"")
        model.beginObservation(); XCTAssertEqual(model.observationDraft.shopID,"")
        model.observationDraft.shopID = granted; model.observationDraft.itemName = "Read-only grant"
        model.reviewObservation(); model.approved = true; await model.applyReviewed()
        XCTAssertNil(model.reviewed); XCTAssertTrue(service.observationSends.isEmpty)
        model.beginPeriod(); XCTAssertEqual(model.periodDraft?.shopIDs, [])
        XCTAssertNotNil(model.periodDraft,"Future planning must not infer entitlement or require an assigned shop in this observation-only guard")
    }
    func testSelectedGrantedShopIsNeverDefaultedIntoObservationWhenAnotherShopIsOwned() async throws {
        let (model, service, _, box) = try await setup()
        let granted = "10000000-0000-4000-8000-000000000004", old = try XCTUnwrap(box.value)
        box.value = .init(generation:old.generation,subject:old.subject,householdID:old.householdID,memberID:old.memberID,currentShopID:granted,authorityStamp:"contributor|store_quotes")
        service.readablePages[nilKey] = .init(shopIds:[granted,shop],nextCursor:nil)
        await model.load(); XCTAssertTrue(model.canBeginObservation)
        enterObservation(model)
        XCTAssertEqual(model.observationDraft.shopID,""); XCTAssertFalse(model.canReviewObservation); XCTAssertNil(model.reviewed)
        model.observationDraft.shopID = granted; model.reviewObservation(); XCTAssertNil(model.reviewed)
        model.observationDraft.shopID = shop; model.reviewObservation(); XCTAssertTrue(model.canReviewObservation)
        guard case .observation(let record) = model.reviewed else { return XCTFail("Explicit owned-shop selection should permit review") }
        XCTAssertEqual(record.shopId,shop)
    }
    func testLostResponseRestoresExactIntentWithoutAutomaticSend() async throws {
        let (model, service, store, box) = try await setup(); enterObservation(model); model.approved = true
        service.loseObservationResponse = true; await model.applyReviewed()
        let original = try XCTUnwrap(model.pending)
        let reopened = HistoryFeatureModel(service: service, store: store, runtime: { box.value })
        await reopened.load(); XCTAssertEqual(reopened.pending, original); XCTAssertEqual(service.observationSends.count, 1)
        service.loseObservationResponse = false; await reopened.retry()
        XCTAssertNil(reopened.pending); XCTAssertEqual(service.observationSends.count, 2)
        XCTAssertEqual(service.observationSends[0].bytes, service.observationSends[1].bytes)
        XCTAssertEqual(service.observationSends[0].id, service.observationSends[1].id)
    }
    func testSaveFailureNeverSendsAndDraftEditInvalidatesReview() async throws {
        let (model, service, store, _) = try await setup(); enterObservation(model); model.approved = true
        model.observationDraft.branch = "South"; XCTAssertNil(model.reviewed); XCTAssertFalse(model.approved)
        model.reviewObservation(); model.approved = true; await store.setSaveFailure(true)
        await model.applyReviewed(); XCTAssertTrue(service.observationSends.isEmpty); XCTAssertNil(model.pending)
    }
    func testConfirmedReceiptCleanupRetryDoesNotResend() async throws {
        let (model, service, store, _) = try await setup(); enterObservation(model); model.approved = true
        await store.setCompleteFailure(true); await model.applyReviewed()
        XCTAssertNotNil(model.pending); XCTAssertEqual(service.observationSends.count, 1)
        await store.setCompleteFailure(false); await model.retry()
        XCTAssertNil(model.pending); XCTAssertEqual(service.observationSends.count, 1)
    }
    func testAuthorityFingerprintChangeStopsPreparationAndClearsVisibleFacts() async throws {
        let (model, service, store, box) = try await setup(); enterObservation(model); model.approved = true
        service.beforePrepare = {
            let old = try XCTUnwrap(box.value)
            box.value = .init(generation: old.generation, subject: old.subject, householdID: old.householdID, memberID: old.memberID, currentShopID: old.currentShopID, authorityStamp: "contributor")
            model.enforceRuntime()
        }
        await model.applyReviewed()
        XCTAssertFalse(model.authorized); XCTAssertNil(model.reviewed); XCTAssertEqual(model.observationDraft.itemName, "")
        XCTAssertTrue(service.observationSends.isEmpty); let state = await store.read(); XCTAssertTrue(state.pending.isEmpty)
    }
    func testPurgeDuringPreparationCannotRecreatePrivatePending() async throws {
        let (model, service, store, _) = try await setup(); enterObservation(model); model.approved = true
        service.beforePrepare = { await store.purge() }
        await model.applyReviewed(); XCTAssertTrue(service.observationSends.isEmpty)
        let state = await store.read(); XCTAssertTrue(state.pending.isEmpty)
    }
    func testPeriodAssignmentRejectsAStaleSelectionAfterSourcesRefresh() async throws {
        let (model, service, _, _) = try await setup()
        model.beginPeriod()
        model.periodDraft?.shopIDs = []
        XCTAssertTrue(model.canAssignPeriodShop(shop))
        service.ownedSources = []
        await model.loadOwnedShops()
        model.assignPeriodShop(shop)
        XCTAssertEqual(model.periodDraft?.shopIDs, [])
        service.ownedSources = nil
        await model.loadOwnedShops()
        model.assignPeriodShop(shop)
        model.assignPeriodShop(shop)
        XCTAssertEqual(model.periodDraft?.shopIDs, [shop])
        XCTAssertFalse(model.canAssignPeriodShop(shop))
    }
    func testSavedPeriodUsesFreshPagedOwnershipForRawAndCalculatedEditActions() async throws {
        let (model, service, _, _) = try await setup()
        let owned = try await service.historyOwnedShops(cursor: nil)
        let other = HistoryOwnedShop(shopId: UUID().uuidString.lowercased(), createdAt: "2025-01-01T00:00:00Z", phase: "closed", revision: 1, authorityEpoch: 1)
        service.ownedPages[nilKey] = .init(shops: [other], nextCursor: other.shopId)
        service.ownedPages[other.shopId] = owned
        for analyze in [false, true] {
            await model.openPeriod(service.saved.periodId, analyze: analyze)
            XCTAssertTrue(model.canEditSelectedPeriod)
            service.ownedPages[other.shopId] = .init(shops: [], nextCursor: nil)
            await model.openPeriod(service.saved.periodId, analyze: analyze)
            XCTAssertNotNil(model.selectedPeriod)
            XCTAssertFalse(model.canEditSelectedPeriod)
            model.editSelectedPeriod()
            XCTAssertNil(model.periodDraft)
            service.ownedPages[other.shopId] = owned
        }
    }
    func testPartialPeriodClearsFullEnvelopeBeforeAwaitAndHidesPendingPlan() async throws {
        let (model, service, _, _) = try await setup()
        await model.openPeriod(service.saved.periodId, analyze: true); model.editSelectedPeriod()
        XCTAssertNotNil(model.selectedPeriod); XCTAssertNotNil(model.periodDraft)
        service.beforePeriodRead = {
            XCTAssertNil(model.selectedPeriod); XCTAssertNil(model.periodAnalysis); XCTAssertNil(model.periodDraft)
        }
        service.analysis = .permittedOnly(service.subtotal)
        await model.openPeriod(service.saved.periodId, analyze: true)
        XCTAssertNil(model.selectedPeriod); XCTAssertNil(model.periodDraft)
        guard case .permittedOnly = model.periodAnalysis else { return XCTFail("Expected only permitted subtotal") }
        XCTAssertNil(model.pending)
    }
    func testPaidLapseClearsAnalysisAndRawPathNeedsFreshRead() async throws {
        let (model, service, _, _) = try await setup()
        await model.openPeriod(service.saved.periodId, analyze: true); XCTAssertNotNil(model.selectedPeriod)
        service.analysisError = ClientError.service(status: 403, code: "membership_inactive", correlationID: nil, retryAfter: nil)
        await model.openPeriod(service.saved.periodId, analyze: true)
        XCTAssertTrue(model.authorized); XCTAssertNil(model.selectedPeriod); XCTAssertNil(model.periodAnalysis)
        let reads = service.rawReads; await model.openPeriod(service.saved.periodId)
        XCTAssertEqual(service.rawReads, reads + 1); XCTAssertEqual(model.selectedPeriod, service.saved); XCTAssertNil(model.periodAnalysis)
    }
    func testPendingPlanIsNotExposedAfterLostPaidOrSourceAuthority() async throws {
        let (model, service, store, box) = try await setup()
        model.beginPeriod(); model.periodDraft?.title = "Private funding"; model.periodDraft?.budget = "100"; model.reviewPeriod(); model.approved = true
        service.losePeriodResponse = true; await model.applyReviewed(); XCTAssertNotNil(model.pending)
        service.authorizationError = ClientError.service(status: 403, code: "membership_inactive", correlationID: nil, retryAfter: nil)
        let reopened = HistoryFeatureModel(service: service, store: store, runtime: { box.value }); await reopened.load()
        XCTAssertNil(reopened.pending); XCTAssertNil(reopened.periodDraft); XCTAssertNil(reopened.selectedPeriod)
        XCTAssertTrue(reopened.hasUnresolvedWrite); XCTAssertFalse(reopened.canEdit); XCTAssertEqual(service.periodSends.count, 1)
        XCTAssertFalse(reopened.periods.isEmpty); XCTAssertFalse(reopened.ownedShops.isEmpty)
    }
    func testPartialResponseHidesPendingPrivatePlanAndBlocksNewWrite() async throws {
        let (model, service, store, _) = try await setup()
        model.beginPeriod(); model.periodDraft?.title = "Private funding"; model.periodDraft?.budget = "100"
        model.reviewPeriod(); model.approved = true; service.losePeriodResponse = true; await model.applyReviewed()
        XCTAssertNotNil(model.pending)
        service.analysis = .permittedOnly(service.subtotal)
        await model.openPeriod(service.saved.periodId, analyze: true)
        XCTAssertNil(model.pending); XCTAssertNil(model.periodDraft); XCTAssertNil(model.selectedPeriod)
        XCTAssertTrue(model.hasUnresolvedWrite); XCTAssertFalse(model.canEdit)
        let saved = await store.read(); XCTAssertEqual(saved.pending.count, 1)
    }
    func testExplicitStatusClearDoesNotSendOrInventConfirmation() async throws {
        let (model, service, store, _) = try await setup(); enterObservation(model); model.approved = true
        service.loseObservationResponse = true; await model.applyReviewed(); XCTAssertNotNil(model.pending)
        service.observationReadError = ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)
        await model.clearPendingAfterStatusReview()
        XCTAssertNil(model.pending); XCTAssertFalse(model.hasUnresolvedWrite); XCTAssertNil(model.selectedObservation)
        XCTAssertEqual(service.observationSends.count, 1)
        let state = await store.read(); XCTAssertTrue(state.pending.isEmpty); XCTAssertTrue(state.observations.isEmpty)
        XCTAssertTrue(model.notice?.contains("does not undo") == true)
    }
    func testStatusClearNeedsFreshAuthorityAndPreservesPrivateRetryOnDenial() async throws {
        let (model, service, store, _) = try await setup(); enterObservation(model); model.approved = true
        service.loseObservationResponse = true; await model.applyReviewed()
        service.authorizationError = ClientError.accessEnded
        await model.clearPendingAfterStatusReview()
        XCTAssertFalse(model.authorized); XCTAssertNil(model.pending); XCTAssertNil(model.selectedObservation)
        let state = await store.read(); XCTAssertEqual(state.pending.count, 1); XCTAssertTrue(state.observations.isEmpty)
    }
    func testOriginalPeriodRevisionAndBytesSurviveUncertainRetry() async throws {
        let (model, service, _, _) = try await setup()
        await model.openPeriod(service.saved.periodId); model.editSelectedPeriod(); model.periodDraft?.budget = "200"
        model.reviewPeriod(); model.approved = true; service.losePeriodResponse = true; await model.applyReviewed()
        service.saved = .init(periodId: service.saved.periodId, revision: 99, period: service.saved.period)
        service.losePeriodResponse = false; await model.retry()
        XCTAssertEqual(service.periodSends.count, 2); XCTAssertEqual(service.periodSends[0].baseRevision, 1)
        XCTAssertEqual(service.periodSends[0].bytes, service.periodSends[1].bytes)
    }
    func testPricePaginationFilterAndAuthorizationFailureDoNotRetainHistory() async throws {
        let (model, service, _, _) = try await setup()
        let first = try service.observation(channel: .warehouse, mode: .pickup, branch: "North")
        let second = try service.observation(channel: .retailerWebsite, mode: .delivery, branch: "South")
        service.pricePages[nilKey] = .init(observations: [first], nextCursor: first.id)
        service.pricePages[first.id] = .init(observations: [second], nextCursor: nil)
        await model.loadPriceHistory(); await model.loadPriceHistory(more: true)
        XCTAssertEqual(model.observations.count, 2)
        model.filter.channel = "warehouse"; model.filter.mode = "pickup"; model.filter.branch = "north"
        XCTAssertEqual(model.filteredObservations.map(\.id), [first.id])
        model.filter.from = Date().addingTimeInterval(1000); XCTAssertTrue(model.filteredObservations.isEmpty)
        service.priceError = ClientError.accessEnded; await model.loadPriceHistory()
        XCTAssertTrue(model.observations.isEmpty); XCTAssertFalse(model.authorized)
    }
    func testRepeatedCursorIsRejectedWithoutDuplicateRows() async throws {
        let (model, service, _, _) = try await setup(); let first = try service.observation()
        service.pricePages[nilKey] = .init(observations: [first], nextCursor: first.id)
        service.pricePages[first.id] = .init(observations: [first], nextCursor: first.id)
        await model.loadPriceHistory(); await model.loadPriceHistory(more: true)
        XCTAssertTrue(model.observations.isEmpty); XCTAssertNil(model.observationCursor)
    }
    func testMoneyUnknownPackAndTerminalReservationEvidenceRemainDistinct() throws {
        XCTAssertEqual(try HistoryMoney.minor("3,49"), 349); XCTAssertEqual(try HistoryMoney.minor("0"), 0)
        XCTAssertNil(try HistoryMoney.minor("", optional: true)); XCTAssertThrowsError(try HistoryMoney.minor(""))
        XCTAssertThrowsError(try HistoryMoney.minor("1,000.00"))
        let fixture = try HistoryFixtureService()
        let final = try HistoryFutureReservation(originalText: "Deferred shop", amountMinor: 1200, plannedAt: "2025-01-03T10:00:00-05:00", state: .released)
        var period = fixture.saved.period; period.reservations = [final]
        var draft = HistoryPeriodDraft(.init(periodId: period.id, revision: 1, period: period))
        XCTAssertEqual(try draft.dto().reservations, [final])
        draft.reservations[0].state = "reserved"; XCTAssertThrowsError(try draft.dto())
        draft = HistoryPeriodDraft(.init(periodId: period.id, revision: 1, period: period)); draft.reservations = []
        XCTAssertThrowsError(try draft.dto())
    }
    func testRealPendingStoreEpochAndAtomicCompletion() async throws {
        let service = try HistoryFixtureService()
        let intent = try await service.preparePriceObservation(service.observation())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryPendingStore(url: url); let epoch = await store.epoch()
        try await store.save(.observation(intent), expectedEpoch: epoch)
        try await store.save(.observation(intent), expectedEpoch: epoch)
        var state = try await store.read(); XCTAssertEqual(state.pending.count, 1)
        let competing = try await service.preparePriceObservation(service.observation())
        do { try await store.save(.observation(competing), expectedEpoch: epoch); XCTFail("Competing action accepted") } catch {}
        try await store.complete(.observation(intent), expectedEpoch: epoch)
        state = try await store.read(); XCTAssertTrue(state.pending.isEmpty); XCTAssertEqual(state.observations.count, 1)
        try await store.purge()
        do { try await store.save(.observation(intent), expectedEpoch: epoch); XCTFail("Purged work recreated") } catch {}
        do { try await store.complete(.observation(intent), expectedEpoch: epoch); XCTFail("Purged reference recreated") } catch {}
        state = try await store.read(); XCTAssertTrue(state.pending.isEmpty); XCTAssertTrue(state.observations.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

private let nilKey = "initial"
@MainActor private final class HistoryScopeBox { var value: HistoryRuntimeScope?; init(_ value: HistoryRuntimeScope) { self.value = value } }
@MainActor private final class HistoryFixtureService: HistoryServing {
    let household = "10000000-0000-4000-8000-000000000001", member = "10000000-0000-4000-8000-000000000002", shop = "10000000-0000-4000-8000-000000000003"
    var saved: HistorySavedBudgetPeriod
    let subtotal: HistoryPermittedSubtotal
    var analysis: HistoryPeriodResponse
    var ownedPages: [String: HistoryOwnedShopPage] = [:]
    var ownedSources: [HistoryOwnedShop]?
    var pricePages: [String: HistoryPriceObservationPage] = [:]
    var readablePages: [String: HistoryReadableShopPage] = [:]
    var priceError: Error?, analysisError: Error?, authorizationError: Error?, observationReadError: Error?
    var beforePrepare: (() async throws -> Void)?, beforePeriodRead: (() async -> Void)?
    var beforeObservationSend: ((PriceObservationIntent) async throws -> Void)?
    var loseObservationResponse = false, losePeriodResponse = false
    var observationSends: [PriceObservationIntent] = [], periodSends: [BudgetPeriodIntent] = []
    var rawReads = 0
    init() throws {
        let period = try HistoryBudgetPeriod(title: "Private period", startsAt: "2025-01-01T00:00:00Z", endsAt: "2025-01-15T00:00:00Z", timeZoneId: "America/New_York", shopBudgetMinor: 10000, alreadyExcludedReserveMinor: 1000, shopIds: [shop], reservations: [], reviewedCompleteAt: nil)
        saved = .init(periodId: period.id, revision: 1, period: period)
        subtotal = .init(shops: [], postedNetMinor: 0, pendingCreditsMinor: 0, includedCreditsMinor: 0, paymentHoldsMinor: 0, expectedUnpaid: .init(lowerMinor: 0, upperMinor: nil), projectedCommitment: .init(lowerMinor: 0, upperMinor: nil))
        analysis = .complete(.init(periodId: period.id, revision: 1, period: period, permitted: subtotal, futureReservedMinor: 0, remaining: .init(minimumMinor: nil, maximumMinor: 10000), reconciledEnteredPeriod: false))
    }
    func observation(channel: HistoryPriceChannel = .storeShelf, mode: HistoryFulfillmentMode = .inStore, branch: String = "North") throws -> HistoryPriceObservation {
        try .init(shopId: shop, itemName: "Oats", packLabel: "12 oz", usablePack: nil, price: .exact(minor: 349), store: "Store", branch: branch, channel: channel, mode: mode, eligibility: "", observedAt: "2025-01-02T12:00:00Z", sourceText: "Shelf label", sourceLocale: "en-US")
    }
    func historyOwnedShops(cursor: String?) async throws -> HistoryOwnedShopPage { ownedPages[cursor ?? nilKey] ?? .init(shops: ownedSources ?? [.init(shopId: shop, createdAt: "2025-01-01T00:00:00Z", phase: "closed", revision: 1, authorityEpoch: 1)], nextCursor: nil) }
    func historyReadableShops(cursor: String?) async throws -> HistoryReadableShopPage { readablePages[cursor ?? nilKey] ?? .init(shopIds: [shop], nextCursor: nil) }
    func priceObservations(cursor: String?) async throws -> HistoryPriceObservationPage { if let priceError { throw priceError }; return pricePages[cursor ?? nilKey] ?? .init(observations: [], nextCursor: nil) }
    func priceObservation(observationID: String) async throws -> HistoryPriceObservation { if let observationReadError { throw observationReadError }; var value = try observation(); value.id = observationID; return value }
    func budgetPeriods(cursor: String?) async throws -> HistoryBudgetPeriodPage { .init(periods: [.init(periodId: saved.periodId, revision: saved.revision, updatedAt: "2025-01-01T00:00:00Z")], nextCursor: nil) }
    func budgetPeriod(periodID: String) async throws -> HistoryPeriodResponse { await beforePeriodRead?(); if let analysisError { throw analysisError }; return analysis }
    func savedBudgetPeriod(periodID: String) async throws -> HistorySavedBudgetPeriod { rawReads += 1; return saved }
    func preparePriceObservation(_ observation: HistoryPriceObservation) async throws -> PriceObservationIntent { try await beforePrepare?(); return try .init(subject: "adult", householdID: household, memberID: member, deviceID: "device", observation: observation) }
    func executePriceObservation(_ intent: PriceObservationIntent) async throws -> PriceObservationReceipt { try await beforeObservationSend?(intent); observationSends.append(intent); if loseObservationResponse { throw ClientError.invalidResponse }; return .init(observationId: intent.observation.id, shopId: intent.observation.shopId) }
    func prepareBudgetPeriod(_ period: HistoryBudgetPeriod, baseRevision: Int) async throws -> BudgetPeriodIntent { try await beforePrepare?(); return try .init(subject: "adult", householdID: household, memberID: member, deviceID: "device", baseRevision: baseRevision, period: period) }
    func executeBudgetPeriod(_ intent: BudgetPeriodIntent) async throws -> BudgetPeriodReceipt { periodSends.append(intent); if losePeriodResponse { throw ClientError.invalidResponse }; return .init(periodId: intent.period.id, revision: intent.baseRevision + 1) }
    func authorizePriceObservation(_ intent: PriceObservationIntent) async throws { if let authorizationError { throw authorizationError } }
    func authorizeBudgetPeriod(_ intent: BudgetPeriodIntent) async throws { if let authorizationError { throw authorizationError } }
}
private actor HistoryFixtureStore: HistoryPersisting {
    var state = HistoryStoredState(), generation = UUID()
    var saveFailure = false, completeFailure = false
    func epoch() -> UUID { generation }
    func read() -> HistoryStoredState { state }
    func setSaveFailure(_ value: Bool) { saveFailure = value }
    func setCompleteFailure(_ value: Bool) { completeFailure = value }
    func addReference(_ value: HistoryStoredReference) { state.observations.append(value) }
    func purge() { generation = UUID(); state = .init() }
    func save(_ pending: HistoryPendingWrite, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }; if saveFailure { throw ClientError.configuration }; state.pending = [pending]
    }
    func complete(_ pending: HistoryPendingWrite, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }; if completeFailure { throw ClientError.configuration }
        state.pending.removeAll { $0.id == pending.id }
        if case .observation(let value) = pending { state.observations.append(.init(subject: value.subject, householdID: value.householdID, memberID: value.memberID, shopID: value.observation.shopId, observationID: value.observation.id)) }
    }
    func remove(id: String, expectedEpoch: UUID) throws { guard generation == expectedEpoch else { throw ClientError.cancelled }; state.pending.removeAll { $0.id == id } }
    func remember(_ reference: HistoryStoredReference, expectedEpoch: UUID) throws { guard generation == expectedEpoch else { throw ClientError.cancelled }; state.observations.append(reference) }
}
