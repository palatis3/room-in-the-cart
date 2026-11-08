import XCTest
import CoreDomain
import HouseholdClient
@testable import RoomInTheCart

final class HouseholdRequestPackReviewTests: XCTestCase {
    private let now = Date()
    private func q(_ amount: Int64, _ unit: UnitOfMeasure = .count) -> Quantity { Quantity(amount:try! Rational(amount),unit:unit,originalLiteral:String(amount)) }
    private func pack(_ id:String, yield:Int64=4, price:Int64?=300, available:RequestPackAvailability = .confirmed, maximum:Int?=nil, matched:Bool=true) -> HouseholdRequestPackCandidate {
        HouseholdRequestPackCandidate(id:id,label:"Reviewed " + id,usable:q(yield),price:price.map { Money(minorUnits:$0) },availability:available,availablePacks:maximum,matchesRequest:matched,feeEligible:true,source:"Reviewed shelf label " + id,observedAt:now)
    }
    func testFixtureInterceptsEveryRequestAndRejectsUnexpectedNetworkDestinations() throws {
        let unexpected = URLRequest(url: URL(string: "https://example.com/unexpected")!)
        XCTAssertTrue(S24FixtureProtocol.canInit(with: unexpected))
        XCTAssertThrowsError(try S24FixtureServer().respond(unexpected))
    }
    func testCheapestUsesWholePacksAndUsableYieldRatherThanStickerPrice() throws {
        let result = try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[pack("A"),pack("B",yield:6,price:400)],at:now)
        XCTAssertEqual(result.cheapestIDs,["A"]); XCTAssertEqual(result.results.map { $0.calculation.packsToBuy },[2,2])
        XCTAssertEqual(result.results.map { $0.calculation.totalCost?.minorUnits },[600,800])
        XCTAssertEqual(result.results[1].calculation.leftover,try Rational(4)); XCTAssertFalse(result.hasUnresolvedAlternatives)
    }
    func testUnavailableInsufficientUnknownAndUnmatchedAreNotCertifiedCheapest() throws {
        for excluded in [pack("A",price:10,available:.unavailable),pack("A",price:10,maximum:1),pack("A",price:10,available:.unknown),pack("A",price:10,matched:false)] {
            let result = try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[excluded,pack("B",yield:8,price:500)],at:now)
            XCTAssertEqual(result.cheapestIDs,["B"]); XCTAssertFalse(result.results[0].canSelect)
        }
        let unknown = try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[pack("A",price:nil),pack("B",yield:8,price:500)],at:now)
        XCTAssertEqual(unknown.cheapestIDs,["B"]); XCTAssertTrue(unknown.hasUnresolvedAlternatives)
        XCTAssertTrue(unknown.results[0].canSelect); XCTAssertNil(unknown.results[0].calculation.totalCost)
    }
    func testUnknownConversionAndYieldNeverInferProductQuantityOrPrice() throws {
        var mass = pack("Mass"); mass.usable=q(100,.gram)
        var missing=pack("Unknown"); missing.usable=nil
        let result = try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[mass,missing],at:now)
        XCTAssertTrue(result.cheapestIDs.isEmpty); XCTAssertTrue(result.results.allSatisfy { !$0.canSelect })
        XCTAssertTrue(result.results[0].calculation.issues.contains(.usableConversionUnknown))
        XCTAssertTrue(result.results[1].calculation.issues.contains(.usableQuantityUnknown))
    }
    func testTiesAndExplicitFreePriceRemainDifferentFromUnknown() throws {
        let result = try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[pack("A",price:0),pack("B",price:0)],at:now)
        XCTAssertEqual(result.cheapestIDs,["A","B"]); XCTAssertEqual(result.results[0].calculation.totalCost,.zero)
        var invalid=pack("Bad"); invalid.source=" "
        XCTAssertThrowsError(try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[invalid],at:now))
        XCTAssertThrowsError(try HouseholdRequestPackReview.calculate(needed:q(0),candidates:[pack("A")],at:now))
    }
    @MainActor private func setup(existing:Bool=false) async throws -> (HouseholdInboxModel,S24FixtureServer,URL) {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        let server=S24FixtureServer(includeExistingLine:existing)
        let model=try await s24FixtureModel(server:server,outboxURL:url)
        model.select(try XCTUnwrap(model.requests.first)); model.choice = .add
        return(model,server,url)
    }
    @MainActor func testReviewedSelectionFeedsActualPreviewAndRequiresExplicitOverageBeforeAtomicApply() async throws {
        let(model,server,url)=try await setup(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let scope=try XCTUnwrap(model.packReviewScope)
        let comparison=try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[pack("A"),pack("B",yield:6,price:400)])
        let selection=try HouseholdRequestPackReview.select(comparison.results[0],needed:q(8),scope:scope)
        XCTAssertTrue(model.usePackSelection(selection)); XCTAssertEqual(server.commandCount,0); XCTAssertNil(server.previewBody)
        await model.review()
        let body=try XCTUnwrap(server.previewBody), decision=try XCTUnwrap(body["decision"] as? [String:Any]), line=try XCTUnwrap(decision["line"] as? [String:Any])
        XCTAssertEqual(body["requestId"] as? String,S24FixtureServer.requestID)
        XCTAssertEqual((body["base"] as? [String:Any])?["authorityEpoch"] as? Int,1)
        XCTAssertEqual(line["originalItem"] as? String,"Reviewed A"); XCTAssertEqual(line["packs"] as? Int,2); XCTAssertEqual(line["unitPriceMinor"] as? Int,300)
        XCTAssertEqual(line["lineId"] as? String,selection.line.id)
        XCTAssertEqual(model.packSelection?.candidate.source,"Reviewed shelf label A")
        let evidence = try XCTUnwrap(decision["reviewedPackEvidence"] as? [String:Any])
        XCTAssertEqual(evidence["quoteSource"] as? String,"Reviewed shelf label A")
        XCTAssertEqual((evidence["needed"] as? [String:Any])?["originalLiteral"] as? String,"8")
        XCTAssertEqual((evidence["usablePerPack"] as? [String:Any])?["numerator"] as? String,"4")
        XCTAssertEqual(evidence["availabilityConfirmed"] as? Bool,true)
        XCTAssertNotNil(evidence["quoteObservedAt"])

        XCTAssertEqual(model.preview?.after.totalMinor,600); XCTAssertFalse(model.canApply)
        await model.apply(); XCTAssertEqual(server.commandCount,0)
        model.acceptOverage=true; XCTAssertTrue(model.canApply)
        await model.apply(); XCTAssertEqual(server.commandCount,1); XCTAssertEqual(server.lineCount,1)
        await model.apply(); XCTAssertEqual(server.commandCount,1)
    }
    @MainActor func testConfirmedApplyWaitsForRefreshedOriginalOutcomeBeforeReturning() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.price = "3.00"; await model.review()
        let held = HeldS24OutcomeResponse()
        defer { S24FixtureProtocol.intercept = nil; held.release() }
        let arrived = expectation(description: "Confirmed Apply is refreshing its original request")
        S24FixtureProtocol.intercept = { task in
            guard task.request.url?.path.hasSuffix("/inbox") == true, server.commandCount > 0 else { return false }
            held.hold(task); arrived.fulfill(); return true
        }
        let apply = Task { await model.apply() }
        await fulfillment(of: [arrived], timeout: 3)
        guard case .confirmed = model.delivery else { return XCTFail("Expected durable receipt before inbox refresh") }
        XCTAssertTrue(model.busy); XCTAssertNil(model.confirmedDecisionRequestID)
        XCTAssertTrue(model.requests.isEmpty, "The old row cannot supply the outcome focus")
        S24FixtureProtocol.intercept = nil; held.release()
        await apply.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.confirmedDecisionRequestID, S24FixtureServer.requestID)
        XCTAssertEqual(model.requests.first?.status, "added")
        XCTAssertEqual(model.requests.first?.revision, 2)
        await model.apply()
        XCTAssertEqual(server.commandCount, 1); XCTAssertEqual(server.lineCount, 1)
        model.clear(); XCTAssertNil(model.confirmedDecisionRequestID)
    }

    @MainActor func testConfirmedApplyRefreshFailureWaitsForSuccessfulRefresh() async throws {
        let (model, server, url) = try await setup()
        defer { S24FixtureProtocol.intercept = nil; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.price = "3.00"; await model.review()
        S24FixtureProtocol.intercept = { task in
            guard task.request.url?.path.hasSuffix("/inbox") == true, server.commandCount > 0 else { return false }
            task.client?.urlProtocol(task, didFailWithError: URLError(.timedOut)); return true
        }
        await model.apply()
        guard case .confirmed = model.delivery else { return XCTFail("The accepted decision must stay confirmed") }
        XCTAssertFalse(model.busy); XCTAssertNil(model.confirmedDecisionRequestID)
        XCTAssertTrue(model.requests.isEmpty)
        S24FixtureProtocol.intercept = nil
        await model.load()
        XCTAssertEqual(model.confirmedDecisionRequestID, S24FixtureServer.requestID)
        XCTAssertEqual(model.requests.first?.status, "added")
        XCTAssertEqual(server.commandCount, 1); XCTAssertEqual(server.lineCount, 1)
    }

    @MainActor func testConfirmedApplyFindsOriginalOutcomeOnLaterInboxPage() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.price = "3.00"; await model.review()
        let held = HeldS24OutcomeResponse()
        defer { S24FixtureProtocol.intercept = nil; held.release() }
        let arrived = expectation(description: "Original confirmed request is on the second inbox page")
        S24FixtureProtocol.intercept = { task in
            guard task.request.url?.path.hasSuffix("/inbox") == true, server.commandCount > 0 else { return false }
            if task.request.url?.query == nil { finishS24FirstOutcomePage(task, server: server) }
            else { held.hold(task); arrived.fulfill() }
            return true
        }
        let apply = Task { await model.apply() }
        await fulfillment(of: [arrived], timeout: 3)
        XCTAssertTrue(model.busy); XCTAssertNil(model.confirmedDecisionRequestID)
        XCTAssertTrue(model.requests.isEmpty, "A partial page cannot replace the original outcome")
        held.release()
        await apply.value
        XCTAssertEqual(model.confirmedDecisionRequestID, S24FixtureServer.requestID)
        XCTAssertEqual(model.requests.map(\.id), [s24OtherRequestID, S24FixtureServer.requestID])
        XCTAssertEqual(model.requests.last?.status, "added")
        XCTAssertNil(model.nextCursor)
        XCTAssertEqual(server.commandCount, 1); XCTAssertEqual(server.lineCount, 1)
    }

    @MainActor func testOutcomePageCycleOrShopChangePreservesReceiptWithoutPublishingPartialRows() async throws {
        for cycle in [true, false] {
            let (model, server, url) = try await setup()
            defer { S24FixtureProtocol.intercept = nil; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            model.price = "3.00"; await model.review()
            S24FixtureProtocol.intercept = { task in
                guard task.request.url?.path.hasSuffix("/inbox") == true, server.commandCount > 0 else { return false }
                if task.request.url?.query == nil { finishS24FirstOutcomePage(task, server: server) }
                else if cycle {
                    let page: [String: Any] = ["requests": [], "nextCursor": s24OtherRequestID]
                    let bytes = try! JSONSerialization.data(withJSONObject: page)
                    finishS24OutcomeResponse(task, status: 200, data: bytes)
                } else {
                    server.advanceSource()
                    task.finishResponse()
                }
                return true
            }
            await model.apply()
            guard case .confirmed = model.delivery else { return XCTFail("Refresh failure must preserve the durable receipt") }
            XCTAssertNil(model.confirmedDecisionRequestID); XCTAssertTrue(model.requests.isEmpty)
            XCTAssertEqual(model.notice, "The decision was confirmed. Refresh requests to see the latest state.")
            // Repeated failed Refresh must not claim that the decision is unconfirmed.
            await model.load()
            XCTAssertNil(model.confirmedDecisionRequestID); XCTAssertTrue(model.requests.isEmpty)
            XCTAssertEqual(model.notice, "The decision was confirmed. Refresh requests to see the latest state.")
            S24FixtureProtocol.intercept = nil
            await model.load()
            XCTAssertEqual(model.confirmedDecisionRequestID, S24FixtureServer.requestID)
            XCTAssertEqual(server.commandCount, 1); XCTAssertEqual(server.lineCount, 1)
        }
    }

    @MainActor func testOutcomeReturnRequiresKnownStateAndAllowsNewerDurableOutcome() async throws {
        for (status, revision, canReturn) in [("unexpected", 2, false), ("pending", 2, false),
                                             ("deferred", 2, false), ("deferred", 3, true), ("withdrawn", 3, true)] {
            let (model, server, url) = try await setup()
            defer { S24FixtureProtocol.intercept = nil; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            model.price = "3.00"; await model.review()
            S24FixtureProtocol.intercept = { task in
                guard task.request.url?.path.hasSuffix("/inbox") == true, server.commandCount > 0 else { return false }
                do {
                    let (_, bytes) = try server.respond(task.request)
                    var page = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    var rows = try XCTUnwrap(page["requests"] as? [[String: Any]])
                    rows[0]["status"] = status; rows[0]["revision"] = revision; page["requests"] = rows
                    finishS24OutcomeResponse(task, status: 200, data: try JSONSerialization.data(withJSONObject: page))
                } catch { task.client?.urlProtocol(task, didFailWithError: error) }
                return true
            }
            await model.apply()
            XCTAssertEqual(model.confirmedDecisionRequestID, canReturn ? S24FixtureServer.requestID : nil,
                           "Outcome \(status) at revision \(revision)")
        }
    }

    @MainActor func testAccessEndsDuringConfirmedRefreshWithoutAnOutcomeReturn() async throws {
        let (model, server, url) = try await setup()
        defer { S24FixtureProtocol.intercept = nil; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.price = "3.00"; await model.review()
        XCTAssertNil(model.confirmedDecisionRequestID)
        S24FixtureProtocol.intercept = { task in
            guard task.request.url?.path.hasSuffix("/inbox") == true, server.commandCount > 0 else { return false }
            finishS24OutcomeResponse(task, status: 403, data: Data())
            return true
        }
        await model.apply()
        XCTAssertFalse(model.authorized); XCTAssertNil(model.confirmedDecisionRequestID)
        XCTAssertNil(model.shop); XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(server.commandCount, 1); XCTAssertEqual(server.lineCount, 1)
    }

    @MainActor func testUnrelatedReceiptAndChangedAuthorityCannotReturnToDecisionOutcome() async throws {
        let replacements: [[String: Any]] = [
            ["kind": "request.clarify"], ["kind": "request.carry"],
            ["requestId": UUID().uuidString], ["authorityEpoch": 2],
            ["requestRevision": 3], ["shopRevision": 3], ["requestRevision": 0], ["shopRevision": 0],
            ["disposition": "unexpected"], ["disposition": "clarified"]
        ]
        for replacement in replacements {
            let (model, server, url) = try await setup()
            defer { S24FixtureProtocol.intercept = nil; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            model.price = "3.00"; await model.review()
            S24FixtureProtocol.intercept = { task in
                guard task.request.url?.path.hasSuffix("/commands") == true else { return false }
                do {
                    let (_, bytes) = try server.respond(task.request)
                    var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    receipt.merge(replacement) { _, changed in changed }
                    finishS24OutcomeResponse(task, status: 200, data: try JSONSerialization.data(withJSONObject: receipt))
                } catch { task.client?.urlProtocol(task, didFailWithError: error) }
                return true
            }
            await model.apply()
            XCTAssertNil(model.confirmedDecisionRequestID, "Mismatched receipt: \(replacement)")
            XCTAssertEqual(model.requests.first?.status, "added")
        }
    }

    @MainActor func testLostReplyAndConflictDoNotReturnEvenWhenRefreshedRowHasOutcome() async throws {
        for conflict in [false, true] {
            let (model, server, url) = try await setup()
            defer { S24FixtureProtocol.intercept = nil; try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            model.price = "3.00"; await model.review()
            S24FixtureProtocol.intercept = { task in
                guard task.request.url?.path.hasSuffix("/commands") == true else { return false }
                if conflict {
                    finishS24OutcomeResponse(task, status: 409, data: Data("{\"error\":{\"code\":\"stale_base\"}}".utf8))
                } else {
                    // The service commits once, but the app never receives its receipt.
                    _ = try? server.respond(task.request)
                    task.client?.urlProtocol(task, didFailWithError: URLError(.timedOut))
                }
                return true
            }
            await model.apply()
            XCTAssertEqual(model.delivery, conflict ? .needsReview : .waiting)
            XCTAssertNotNil(model.pending); XCTAssertNil(model.confirmedDecisionRequestID)
            S24FixtureProtocol.intercept = nil
            await model.load()
            XCTAssertEqual(model.requests.first?.status, conflict ? "pending" : "added")
            XCTAssertNil(model.confirmedDecisionRequestID)
        }
    }

    @MainActor func testUnknownSelectedPriceAndManualPathKeepExplicitUnknownAcknowledgment() async throws {
        let(model,server,url)=try await setup(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let scope=try XCTUnwrap(model.packReviewScope)
        let comparison=try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[pack("A",price:nil)])
        XCTAssertTrue(model.usePackSelection(try HouseholdRequestPackReview.select(comparison.results[0],needed:q(8),scope:scope)))
        await model.review(); XCTAssertTrue(model.preview?.requiresUnknownAcceptance == true); XCTAssertFalse(model.canApply)
        model.acceptUnknown=true; XCTAssertTrue(model.canApply)
        model.lineItem="Manual choice"; XCTAssertNil(model.packSelection); XCTAssertNil(model.preview)
        model.packs=1; model.price=""; await model.review()
        XCTAssertTrue(model.preview?.requiresUnknownAcceptance == true)
        let line=((server.previewBody?["decision"] as? [String:Any])?["line"] as? [String:Any])
        XCTAssertNil((server.previewBody?["decision"] as? [String:Any])?["reviewedPackEvidence"])
        XCTAssertEqual(line?["originalItem"] as? String,"Manual choice"); XCTAssertTrue(line?["unitPriceMinor"] is NSNull)
    }
    @MainActor func testRefreshScopeAndAccessLossInvalidatePackSelectionAndLinkStaysZeroAddition() async throws {
        let(model,server,url)=try await setup(existing:true); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let scope=try XCTUnwrap(model.packReviewScope)
        let row=try HouseholdRequestPackReview.calculate(needed:q(8),candidates:[pack("A")]).results[0]
        let selection=try HouseholdRequestPackReview.select(row,needed:q(8),scope:scope)
        XCTAssertTrue(model.usePackSelection(selection))
        server.advanceSource(); await model.load(); XCTAssertNil(model.packSelection)
        // Quote observation changes on refreshed source even with unchanged numeric revision.
        XCTAssertThrowsError(try selection.validate(scope:XCTUnwrap(model.packReviewScope)))
        model.choice = .link; model.linkedLineID="77777777-7777-4777-8777-777777777777"; await model.review()
        XCTAssertEqual(model.preview?.changeMinor,0); XCTAssertEqual((server.previewBody?["decision"] as? [String:Any])?["choice"] as? String,"link")
        XCTAssertEqual(server.commandCount,0)
        model.cancelReview(); XCTAssertNil(model.selected); XCTAssertNil(model.preview)
        model.clear(); XCTAssertFalse(model.usePackSelection(selection)); XCTAssertNil(model.packReviewScope)
    }
}

private final class HeldS24OutcomeResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var task: S24FixtureProtocol?
    func hold(_ value: S24FixtureProtocol) { lock.lock(); task = value; lock.unlock() }
    func release() {
        lock.lock(); let value = task; task = nil; lock.unlock()
        value?.finishResponse()
    }
}
private func finishS24OutcomeResponse(_ task: S24FixtureProtocol, status: Int, data: Data) {
    let response = HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
    task.client?.urlProtocol(task, didReceive: response, cacheStoragePolicy: .notAllowed)
    task.client?.urlProtocol(task, didLoad: data)
    task.client?.urlProtocolDidFinishLoading(task)
}

private let s24OtherRequestID = "77777777-7777-4777-8777-777777777777"
private func finishS24FirstOutcomePage(_ task: S24FixtureProtocol, server: S24FixtureServer) {
    do {
        let (_, bytes) = try server.respond(task.request)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var other = try XCTUnwrap((original["requests"] as? [[String: Any]])?.first)
        other["requestId"] = s24OtherRequestID; other["originalItem"] = "Other request"
        other["revision"] = 1; other["status"] = "pending"; other["ownActionAllowed"] = true
        let page: [String: Any] = ["requests": [other], "nextCursor": s24OtherRequestID]
        finishS24OutcomeResponse(task, status: 200, data: try JSONSerialization.data(withJSONObject: page))
    } catch { task.client?.urlProtocol(task, didFailWithError: error) }
}
