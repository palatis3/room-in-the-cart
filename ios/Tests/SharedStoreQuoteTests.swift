import XCTest
import CoreDomain
import HouseholdClient
@testable import RoomInTheCart

private actor StoreQuoteFixture: SharedStoreQuotesServing {
    let scope: StoreQuoteScope
    var page: StoreQuotePage
    var lost = false, denied = false
    var sends: [StoreQuoteIntent] = []
    var readHook: (@Sendable () async -> Void)?
    init(scope: StoreQuoteScope, page: StoreQuotePage) { self.scope = scope; self.page = page }
    func lose(_ flag: Bool) { lost = flag }
    func deny(_ flag: Bool) { denied = flag }
    func replace(_ value: StoreQuotePage) { page = value }
    func onRead(_ value: (@Sendable () async -> Void)?) { readHook = value }
    func sent() -> [StoreQuoteIntent] { sends }
    func storeQuotes(shopID: UUID, cursor: UUID?) async throws -> StoreQuotePage {
        await readHook?(); if denied { throw ClientError.accessEnded }; return page
    }
    func prepareStoreQuote(shopID: UUID, action: StoreQuoteAction, request: StoreQuoteWrite) async throws -> StoreQuoteIntent {
        let current = try await storeQuotes(shopID:shopID,cursor:nil)
        guard current.shopRevision == request.shopRevision, current.authorityEpoch == request.authorityEpoch, current.grantRevision == request.grantRevision else { throw ClientError.accessEnded }
        return try .init(context:.init(subject:scope.subject,householdID:scope.householdID,memberID:scope.memberID,deviceID:"enrolled-device"),shopID:shopID,action:action,request:request,reviewedCommitments:current.commitments)
    }
    func authorizeStoreQuote(_ intent: StoreQuoteIntent) async throws {
        let current = try await storeQuotes(shopID:intent.shopID,cursor:nil)
        guard current.authorityEpoch == intent.request.authorityEpoch, current.grantRevision == intent.request.grantRevision else {
            throw ClientError.service(status:409,code:"quote_authority_changed",correlationID:nil,retryAfter:nil)
        }
    }
    func executeStoreQuote(_ intent: StoreQuoteIntent) async throws -> StoreQuoteReceipt {
        try await authorizeStoreQuote(intent); sends.append(intent)
        if lost { throw ClientError.transport }
        return try JSONDecoder().decode(StoreQuoteReceipt.self,from:JSONSerialization.data(withJSONObject:["operationId":intent.id.uuidString,"shopRevision":intent.request.shopRevision + (intent.action == .adoptions ? 1 : 0)]))
    }
}
@MainActor final class SharedStoreQuoteTests: XCTestCase {
    private func scope() -> StoreQuoteScope { .init(generation:UUID(),enrollmentRevision:UUID(),subject:"verified-adult",householdID:UUID().uuidString,memberID:UUID().uuidString,shopID:UUID(),authorityStamp:"contributor/store_quotes") }
    private func option(_ label: String = "First", checkout: Int? = 3800, trip: Int? = 0, minutes: Int? = 0) -> EnteredStoreQuote {
        .init(label:label,store:label,branch:"Branch",mode:"pickup",slot:"2026-11-05T18:00:00Z",observedAt:"2026-11-03T12:00:00Z",source:"Entered checkout",itemsMinor:checkout,checkoutMinor:checkout,allChargesIncluded:true,available:true,quantitiesMatched:true,singleStore:true,tripAlreadyPlanned:trip == 0,tripMinor:trip,extraMinutes:minutes,capMinor:3800,eligibilityConfirmed:true)
    }
    private func page(_ scope: StoreQuoteScope, shopper: Bool = false, revision: Int = 3, epoch: Int = 2, grant: Int = 1, phase: String = "draft", pairs: [Any] = [], adults: [Any] = []) throws -> StoreQuotePage {
        try JSONDecoder().decode(StoreQuotePage.self,from:JSONSerialization.data(withJSONObject:["shopId":scope.shopID.uuidString,"shopRevision":revision,"authorityEpoch":epoch,"grantRevision":shopper ? 0 : grant,"shopper":shopper,"phase":phase,"adults":adults,"commitments":[["id":"11111111-1111-4111-8111-111111111111","label":"Wraps for dinner and lunch","packs":2]],"currentBasis":NSNull(),"pairs":pairs,"nextCursor":NSNull()]))
    }
    private func storeURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("quote-tests-" + UUID().uuidString).appendingPathComponent("retry.json") }
    func testNativeCoreEngineShowsOneDollarMoreEighteenMinutesAndThreeDollarBreakEven() throws {
        let scope = scope(), page = try page(scope), first = option(), second = option("Second",checkout:3500,trip:400,minutes:18)
        var result = try SharedStoreQuoteMath.compare(.init(first:first,second:second),commitments:page.commitments,shopID:scope.shopID)
        XCTAssertEqual(result.checkoutChange?.minorUnits,-300); XCTAssertEqual(result.tripCashChange?.minorUnits,100)
        XCTAssertEqual(result.extraMinutesChange,18); XCTAssertEqual(result.preferredByTotalCash,SharedStoreQuoteMath.firstID)
        var unknown = second; unknown.tripMinor = nil
        result = try SharedStoreQuoteMath.compare(.init(first:first,second:unknown),commitments:page.commitments,shopID:scope.shopID)
        XCTAssertNil(result.preferredByTotalCash); XCTAssertNil(result.tripCashChange); XCTAssertEqual(result.secondTripCashBreakEven?.minorUnits,300)
        switch try SharedStoreQuoteMath.capAssessment(second,commitmentsID:scope.shopID) {
        case .within(_,let headroom): XCTAssertEqual(headroom.minorUnits,300,"Trip cost must not be compared to grocery cap")
        default: XCTFail("Expected checkout headroom")
        }
    }
    func testMissingChargesUnavailableAndUnreviewedEligibilityCannotCrownWinner() throws {
        let scope = scope(), page = try page(scope), first = option()
        for index in 0..<5 {
            var second = option("Second",checkout:3500,trip:0)
            if index == 0 { second.allChargesIncluded = false }
            if index == 1 { second.available = nil }
            if index == 2 { second.available = false }
            if index == 3 { second.eligibilityConfirmed = false }
            if index == 4 { second.quantitiesMatched = false }
            let result = try SharedStoreQuoteMath.compare(.init(first:first,second:second),commitments:page.commitments,shopID:scope.shopID)
            XCTAssertNil(result.preferredByTotalCash,"unresolved case \(index)")
            if index == 4 { XCTAssertFalse(result.comparable); XCTAssertNil(result.checkoutChange) }
        }
    }
    func testLostReplySurvivesRestartRetriesSameBytesAndBlocksEditedSave() async throws {
        let scope = scope(), page = try page(scope), service = StoreQuoteFixture(scope:scope,page:page), url = storeURL()
        let options = EnteredStoreQuoteOptions(first:option(),second:option("Second",checkout:3500,trip:400))
        await service.lose(true)
        let model = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:url),runtime:{scope})
        await model.load(); await model.prepareSave(options); await model.sendReviewed()
        let pending = try XCTUnwrap(model.pending)
        await model.prepareSave(.init(first:option("Changed"),second:option("Other")))
        XCTAssertNil(model.review); model.invalidate(); await service.lose(false)
        let restarted = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:url),runtime:{scope})
        await restarted.load(); XCTAssertEqual(restarted.pending,pending)
        await restarted.retry(); XCTAssertFalse(restarted.hasPending)
        let sends = await service.sent(); XCTAssertEqual(sends,[pending,pending]); XCTAssertEqual(sends[0].bytes,sends[1].bytes)
    }
    func testAccountOrEnrollmentChangeDiscardsLateReadAndBlocksSend() async throws {
        let scope = scope(), service = StoreQuoteFixture(scope:scope,page:try page(scope))
        var runtime: StoreQuoteScope? = scope
        let model = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:storeURL()),runtime:{runtime})
        await service.onRead { await MainActor.run { runtime = nil } }
        await model.load(); XCTAssertNil(model.page)
        await model.prepareSave(.init(first:option(),second:option("Second")))
        await model.sendReviewed(); let sent = await service.sent(); XCTAssertTrue(sent.isEmpty)
    }
    func testRevocationHidesProtectedRetryAndCannotReplayPriorSuccess() async throws {
        let scope = scope(), service = StoreQuoteFixture(scope:scope,page:try page(scope)), url = storeURL()
        await service.lose(true)
        let first = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:url),runtime:{scope})
        await first.load(); await first.prepareSave(.init(first:option(),second:option("Second"))); await first.sendReviewed()
        XCTAssertNotNil(first.pending); first.invalidate(); await service.deny(true)
        let next = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:url),runtime:{scope})
        await next.load(); XCTAssertNil(next.page); XCTAssertNil(next.pending); XCTAssertFalse(next.authorized)
        await next.retry(); let sent = await service.sent(); XCTAssertEqual(sent.count,1)
    }
    func testPurgeAdvancesEpochAndRejectsPreDeletionWrite() async throws {
        let scope = scope(), page = try page(scope), service = StoreQuoteFixture(scope:scope,page:page), store = StoreQuotesPendingStore(url:storeURL())
        let epoch = await store.epoch(), request = StoreQuoteWrite(page:page,options:.init(first:option(),second:option("Second")))
        let intent = try await service.prepareStoreQuote(shopID:scope.shopID,action:.pairs,request:request)
        try await store.save(intent,expectedEpoch:epoch)
        try await store.purge(householdID:scope.householdID,subject:scope.subject)
        do { try await store.save(intent,expectedEpoch:epoch); XCTFail("Pre-deletion task rewrote data") } catch ClientError.cancelled {}
        let values = try await store.read(); XCTAssertTrue(values.isEmpty)
    }
    func testFrozenShopperCanReviewRevokingNamedBudgetAccessWithoutBasketWrite() async throws {
        let scope = scope(), adult = UUID()
        let page = try page(scope,shopper:true,phase:"frozen",adults:[["id":adult.uuidString,"label":"Second adult","revision":2,"enabled":true]])
        let service = StoreQuoteFixture(scope:scope,page:page)
        let model = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:storeURL()),runtime:{scope})
        await model.load(); XCTAssertFalse(model.canPrepare); XCTAssertTrue(model.canManageGrants)
        await model.prepareGrant(page.adults[0],enabled:false)
        XCTAssertEqual(model.review?.action,.grants); XCTAssertEqual(model.review?.request.adultId,adult)
        await model.sendReviewed(); let sent = await service.sent()
        XCTAssertEqual(sent.count,1); XCTAssertEqual(sent[0].action,.grants); XCTAssertEqual(sent[0].request.enabled,false)
    }
    func testNewShopperEpochHidesOldPendingAndAllowsExplicitLocalClearWithoutRebase() async throws {
        let scope = scope(), service = StoreQuoteFixture(scope:scope,page:try page(scope)), url = storeURL()
        await service.lose(true)
        let first = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:url),runtime:{scope})
        await first.load(); await first.prepareSave(.init(first:option(),second:option("Second"))); await first.sendReviewed()
        let original = try XCTUnwrap(first.pending); first.invalidate()
        await service.replace(try page(scope,epoch:3)); await service.lose(false)
        let next = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:url),runtime:{scope})
        await next.load(); XCTAssertTrue(next.hasPending); XCTAssertNil(next.pending); XCTAssertNil(next.page)
        await next.retry(); let sent = await service.sent(); XCTAssertEqual(sent,[original])
        await next.clearPendingAfterRefresh(); XCTAssertFalse(next.hasPending); XCTAssertEqual(next.page?.authorityEpoch,3)
    }
    func testFrozenShopDoesNotPrepareNewPrivateSave() async throws {
        let scope = scope(), service = StoreQuoteFixture(scope:scope,page:try page(scope,phase:"frozen"))
        let model = SharedStoreQuotesModel(scope:scope,service:service,store:.init(url:storeURL()),runtime:{scope})
        await model.load(); await model.prepareSave(.init(first:option(),second:option("Second")))
        XCTAssertNil(model.review); let sent = await service.sent(); XCTAssertTrue(sent.isEmpty)
    }
}
