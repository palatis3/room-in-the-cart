import XCTest
@testable import HouseholdClient

final class SharedTrackingWriteTests: XCTestCase {
    typealias F = TrackingWriteFixture
    func testAllSixIntentShapesAndCompleteDisclosuresValidate() throws {
        let expected: [String: Set<String>] = ["adopt": ["mode", "base", "action", "change", "packs"], "change": ["mode", "base", "action", "change", "packs", "unboundFactIds"], "review": ["mode", "base", "action", "packs"], "firstAdoptionUndo": ["mode", "base", "targetOperationId", "packs"], "rebind": ["mode", "base", "bindings"], "recover": ["mode", "base", "packs"]]
        for mode in ["adopt", "change", "review", "firstAdoptionUndo", "rebind", "recover", "request"] {
            let f = try F.scenario(mode), intent = try F.intent(f), accepted = try F.accepted(f)
            let wire = try JSONSerialization.jsonObject(with: encoded(intent)) as! [String: Any]
            XCTAssertEqual(Set(wire.keys), expected[intent.kind.mode])
            XCTAssertEqual(Set((wire["base"] as! [String: Any]).keys), ["shopRevision", "authorityEpoch", "graphRevision", "stateDigest"])
            XCTAssertEqual(accepted.preview.disclosure.wire, accepted.candidateReview.candidate.disclosure.wire)
            XCTAssertFalse(accepted.preview.disclosure.pickup.coverage.completeFoodCoverage)
        }
    }
    func testCandidateRejectsChangedActionOmittedNullAndUnknownNestedFields() throws {
        let f = try F.scenario()
        for (path, value) in [("candidate.extra", "bad"), ("candidate.action.body.quote.extra", "bad"), ("candidate.disclosure.pickup.extra", "bad"), ("candidate.after.catalog.0.source.extra", "bad")] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, value) as! [String: Any]), path)
        }
        for path in ["candidate.disclosure.changes", "candidate.disclosure.pickup.unbound.0.transferred"] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, nil) as! [String: Any]), path)
        }
        let changed: SharedTrackingCandidate = try F.decode((F.edit(f, "candidate.action.body.lines.0.packs", 2) as! [String: Any])["candidate"]!)
        XCTAssertThrowsError(try SharedTrackingCandidateReview(page: F.decode(f["page"]!), intent: F.intent(f), candidate: changed))
    }
    func testAcknowledgementMustRetainExactCandidateActionDisclosureTokenAndExpiry() throws {
        let f = try F.scenario()
        for (path, value) in [("preview.previewId", F.id(99)), ("preview.expiresAt", "2099-01-01T00:00:00Z"), ("preview.action.body.lines.0.originalItem", "Changed food"), ("preview.disclosure.pickup.stateDigest", String(repeating: "a", count: 64))] {
            XCTAssertThrowsError(try F.accepted(F.edit(f, path, value) as! [String: Any]), path)
        }
        XCTAssertThrowsError(try F.accepted(F.edit(f, "preview.trackingVersion", 1) as! [String: Any]))
        XCTAssertThrowsError(try F.accepted(F.edit(f, "preview.disclosure.pickup.coverage.completeFoodCoverage", true) as! [String: Any]))
    }
    func testPickupMustDiscloseUnboundProtectionUnpricedRowsAndUnresolvedPacks() throws {
        let f = try F.scenario("rebind")
        for path in ["candidate.disclosure.pickup.unpricedBasketIds", "candidate.disclosure.pickup.unresolvedPackIds"] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, []) as! [String: Any]), path)
        }
        let partial = try F.scenario()
        XCTAssertThrowsError(try F.candidateReview(F.edit(partial, "candidate.disclosure.pickup.unbound", []) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(partial, "candidate.disclosure.pickup.coverage.protectedUnboundFactIds", []) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(partial, "candidate.disclosure.pickup.coverage.allocatableUnboundFactIds", [F.id(22)]) as! [String: Any]))
    }
    func testUndoBindsTargetAndAllReversedAssertionsWithoutDroppingLaterIDs() throws {
        let f = try F.scenario("firstAdoptionUndo")
        for (path, value) in [("candidate.disclosure.changes.targetOperationId", F.id(99)), ("candidate.disclosure.changes.reversedAssertions.contributions.0.originalText", "Replacement"), ("candidate.disclosure.changes.reversedAssertions.lines.0.name", "Replacement")] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, value) as! [String: Any]), path)
        }
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.transferredFactIds", []) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.after.graph.usedIds", [F.id(10), F.id(11), F.id(20)]) as! [String: Any]))
    }
    func testRebindCannotChangeProtectedTransferOrRestoreOldAllocations() throws {
        let f = try F.scenario("rebind")
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.allocationsRestored", [F.id(70)]) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.restored.0.after.originalText", "Unprotected") as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.restored.0.before.transferred", NSNull()) as! [String: Any]))
    }
    func testRecoveryMustUseCurrentSurvivorsAndFreshPacks() throws {
        let f = try F.scenario("recover")
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.invalidatedStateDigest", String(repeating: "a", count: 64)) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.survivingCatalog", []) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "candidate.disclosure.changes.freshPackReviews", []) as! [String: Any]))
        let p: SharedTrackingPage = try F.decode(f["page"]!)
        XCTAssertThrowsError(try SharedTrackingIntent(page: p, context: F.context, kind: .review(action: F.decode((f["candidate"] as! [String: Any])["action"]!), packs: [])))
    }
    func testRequestBaseRequiresExplicitOriginalPreviewNotHistoricalCatalogRevision() throws {
        let f = try F.scenario("request"), intent = try F.intent(f)
        XCTAssertEqual(intent.requestPreview?.requestRevision, 6)
        let p: SharedTrackingPage = try F.decode(f["page"]!)
        XCTAssertThrowsError(try SharedTrackingIntent(page: p, context: F.context, kind: intent.kind))
        for (path, value) in [("requestPreview.requestRevision", 5), ("requestPreview.shopRevision", 9)] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, value) as! [String: Any]), path)
        }
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "requestPreview.previewId", F.id(99)) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(f, "requestPreview.choice", "defer") as! [String: Any]))
    }
    func testActionRejectsInvalidQuoteAndExplicitNewRebindBasketStaysUnpriced() throws {
        let f = try F.scenario()
        for (path, value) in [("candidate.action.body.quote.currency", "CAD"), ("candidate.action.body.quote.observedAt", "not-a-date"), ("candidate.action.body.quote.scope", "unbounded")] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, value) as! [String: Any]))
        }
        let basket = try SharedTrackingBasketLine.reviewed(id: SharedDemandID(), name: "Authored food", packs: 1, priceMinor: nil, feeEligible: true)
        let wire = try JSONSerialization.jsonObject(with: encoded(basket)) as! [String: Any]
        XCTAssertTrue(wire["priceMinor"] is NSNull)
        XCTAssertThrowsError(try SharedTrackingBasketLine.reviewed(id: SharedDemandID(), name: "Authored food", packs: 0, priceMinor: nil, feeEligible: true))
    }
    func testVersionStatePrivacyAndFreshnessCannotDrift() throws {
        let f = try F.scenario()
        for (path, value) in [("candidate.schemaVersion", 1), ("candidate.after.graph.revision", 5), ("candidate.after.authorityEpoch", 4), ("candidate.after.privacyRevision", 6)] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(f, path, value) as! [String: Any]), path)
        }
        for expiry in ["2020-01-01T00:00:00Z", "2099-01-01T00:00:00Z"] {
            let review = try F.candidateReview(F.edit(f, "candidate.expiresAt", expiry) as! [String: Any])
            XCTAssertThrowsError(try review.requireFresh())
        }
    }
}
