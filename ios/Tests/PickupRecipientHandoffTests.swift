import XCTest
import CoreDomain
@testable import RoomInTheCart

final class PickupRecipientHandoffTests: XCTestCase {
    let shopID = UUID()
    func copy(_ pieces: [HandoffPiece]?, shop: UUID? = nil, channel: HandoffChannel = .cook, language: String = "en-US", privateText: Bool = false) -> HandoffCopy {
        HandoffCopy(shopID: shop ?? shopID, channel: channel, versionID: UUID(), revision: 2, language: language,
                    fullText: "Entire reviewed instruction", pieces: pieces, needsPrivateReview: privateText)
    }
    func testTypedChangesKeepSameNameQuantitiesAndUnresolvedNeedsSeparate() {
        let old = copy([.init(key: "a",text: "Anne: 2 wraps",unresolved: nil), .init(key: "b",text: "Ben: 2 wraps",unresolved: nil),
                        .init(key: "c",text: "Milk",unresolved: nil)])
        let current = copy([.init(key: "a",text: "Anne: 3 wraps",unresolved: "Anne: check 1 wrap"),
                            .init(key: "b",text: "Ben: 2 wraps",unresolved: nil),.init(key: "d",text: "Eggs",unresolved: nil)])
        XCTAssertEqual(HandoffCorrection.review(current: current, prior: old, paid: true, destinationConfirmed: true, privateWordingConfirmed: false),
                       .changes(added: ["Anne: 3 wraps","Eggs"], removed: ["Anne: 2 wraps","Milk"], unresolved: ["Anne: check 1 wrap"]))
    }
    func testFullFallbackForUnknownWrongRecipientContextAndLapseAndPrivateCopies() {
        let current = copy([]), prior = copy([.init(key: "old",text: "private prior",unresolved: nil)])
        for (old,paid,certain) in [(nil,true,true),(prior,false,true),(prior,true,false),(copy([],shop: UUID()),true,true),
                                  (copy([],channel: .retailer),true,true),(copy([],language: "es-US"),true,true),(copy(nil,privateText: true),true,true)] {
            XCTAssertEqual(HandoffCorrection.review(current: current, prior: old, paid: paid, destinationConfirmed: certain, privateWordingConfirmed: false),.full(current.fullText))
        }
        let edited = copy(nil,privateText: true)
        XCTAssertNil(HandoffCorrection.review(current: edited, prior: prior, paid: true, destinationConfirmed: true, privateWordingConfirmed: false))
        XCTAssertEqual(HandoffCorrection.review(current: edited, prior: prior, paid: true, destinationConfirmed: true, privateWordingConfirmed: true),.full(edited.fullText))
    }
    @MainActor func testSystemHandoffResultsKeepTheirOriginalVersionsAfterPickupChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url)
        let quantity = Quantity(amount: try Rational(1), unit: .count, originalLiteral: "1")
        let line = BasketLine(id: UUID(), name: "Beans", quantity: quantity, expectedCost: .exact(.zero))

        func freeze(_ pickupID: UUID) async throws -> HandoffSnapshot {
            let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "Evening",
                                          commitmentsID: pickupID, observedAt: Date(), source: "Reviewed checkout")
            let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.zero)))
            let started = await model.start(from: [line], shopID: pickupID, context: context)
            let quoted = await model.setQuote(quote, cap: nil)
            let frozen = await model.freeze()
            XCTAssertTrue(started && quoted && frozen)
            return try XCTUnwrap(model.frozenSnapshot)
        }

        let first = try await freeze(shopID)
        let note = PickupCookNote(id: UUID(), text: "Save the beans for soup", language: "en-US", createdAt: Date(), revision: 1)
        let saved = await model.change { $0.notes.append(note) }
        XCTAssertTrue(saved)
        let copy = try XCTUnwrap(model.handoffCopy(channel: .cook, versionID: note.id, language: "en-US"))
        let retailerOpened = await model.recordHandoff(.shareOpened, snapshot: first)
        let cookOpened = await model.recordCookShare(.shareOpened, copy: copy)
        XCTAssertTrue(retailerOpened && cookOpened)
        let reopened = await model.reopenDraft()
        XCTAssertTrue(reopened)
        let replacement = try await freeze(shopID)
        XCTAssertNotEqual(first.id, replacement.id)
        let stale = await model.recordHandoff(.shareOpened, snapshot: first)
        XCTAssertFalse(stale)
        let other = try await freeze(UUID())

        let cancelled = await model.recordHandoff(.shareCancelled, snapshot: first)
        let completed = await model.recordCookShare(.shareCompleted, copy: copy, destination: "fixture share destination")
        XCTAssertTrue(cancelled && completed)
        XCTAssertEqual(model.selectedID, other.basketID)
        XCTAssertEqual(model.frozenSnapshot, other)
        XCTAssertTrue(model.journey?.cookShareEvents.isEmpty == true)

        let restored = PickupModel(databaseURL: url)
        await restored.load()
        let pickup = try XCTUnwrap(restored.journeys.first { $0.id == shopID })
        let basket = try XCTUnwrap(pickup.basket)
        XCTAssertEqual(basket.handoffActions.filter { $0.kind == .shareCancelled }.map(\.snapshotID), [first.id])
        XCTAssertTrue(basket.placements.isEmpty)
        XCTAssertEqual(basket.current.id, replacement.revision.id)
        XCTAssertEqual(pickup.cookShareEvents.map(\.noteID), [note.id, note.id])
        XCTAssertEqual(pickup.cookShareEvents.map(\.action), [.shareOpened, .shareCompleted])
        XCTAssertNil(pickup.lastSend(.cook, recipient: "fixture share destination"))
    }

    @MainActor func testSentAndAcknowledgedSurviveRestartAndEraseWithPickup() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url)
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "Evening", commitmentsID: shopID, observedAt: Date(), source: "Private budget details")
        let quantity = Quantity(amount: try Rational(1), unit: .count, originalLiteral: "1")
        let line = BasketLine(id: UUID(), name: "Beans", quantity: quantity, expectedCost: .unknown(reason: "PRIVATE"))
        _ = await model.start(from: [line], shopID: shopID, context: context)
        _ = await model.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.zero))), cap: nil)
        _ = await model.freeze()
        let snapshot = try XCTUnwrap(model.frozenSnapshot)
        let version = try XCTUnwrap(model.handoffCopy(channel: .retailer, versionID: snapshot.id, language: "en-US"))
        let revision = try XCTUnwrap(model.journey?.revision)
        _ = await model.recordHandoff(.intentionallySent, destination: "some share activity")
        _ = await model.recordHandoff(.shareCancelled)
        XCTAssertNil(model.journey?.lastSend(.retailer, recipient: "Cook"))
        let stale = await model.markRecipient(version, recipient: "Cook", acknowledge: false, reviewedRevision: revision)
        XCTAssertFalse(stale)
        let base = try XCTUnwrap(model.journey?.revision)
        let first = await model.markRecipient(version, recipient: "Cook", acknowledge: false, reviewedRevision: base)
        XCTAssertTrue(first)
        let sent = try XCTUnwrap(model.journey?.lastSend(.retailer, recipient: "Cook"))
        XCTAssertNil(sent.acknowledgedAt)
        let retry = await model.markRecipient(version, recipient: "Cook", acknowledge: false, reviewedRevision: base)
        XCTAssertTrue(retry); XCTAssertEqual(model.journey?.revision,base + 1)
        let second = await model.markRecipient(version, recipient: "Sam", acknowledge: false, reviewedRevision: base + 1)
        XCTAssertTrue(second)
        let ack = await model.markRecipient(version, recipient: "Cook", acknowledge: true, reviewedRevision: base + 2)
        XCTAssertTrue(ack)
        XCTAssertNil(model.journey?.lastSend(.cook, recipient: "Cook"))
        let reopened = PickupModel(databaseURL: url)
        await reopened.load()
        XCTAssertNotNil(reopened.journey?.lastSend(.retailer, recipient: "Cook")?.acknowledgedAt)
        XCTAssertNil(reopened.journey?.lastSend(.retailer, recipient: "Sam")?.acknowledgedAt)
        XCTAssertEqual(reopened.journey?.recipientSends?.count,2)
        XCTAssertEqual(version.pieces?.first?.unresolved,"Beans · Confirm the price")
        XCTAssertFalse(version.fullText.contains("PRIVATE"))
        let listing = try await reopened.archiveSnapshot()
        try await reopened.deleteArchived(id: shopID, expectedRevision: XCTUnwrap(listing.records.first?.revision), operationID: UUID())
        let afterErase = PickupModel(databaseURL: url); await afterErase.load()
        XCTAssertNil(afterErase.journey)
    }

    @MainActor func testSpanishCookUsesOnlyTheSelectedRecipientsLastExplicitVersionAndLiveSeat() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url), at = Date()
        let q = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "dos")
        let urgent = UrgentMealNeed(id: UUID(), food: "Frijoles", meal: "Sopa", required: q, available: q, due: nil, confirmedAt: at)
        _ = await model.addUrgent(urgent)
        func saveCookCopy() async throws -> HandoffCopy {
            let j = try XCTUnwrap(model.journey), zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            let text = PickupCookProjection.text(journey: j, allocation: model.allocation, result: nil, language: "es-US", at: at, timeZone: zone)
            var note = PickupCookNote(id: UUID(), text: text, language: "es-US", createdAt: at, revision: j.revision)
            note.reviewedHandoff = .init(pieces: PickupCookProjection.pieces(journey: j, allocation: model.allocation, language: "es-US", timeZone: zone),
                                         timeZoneID: zone.identifier, includesBudget: false, customWording: false, budget: nil)
            _ = await model.change { $0.notes.append(note) }
            return try XCTUnwrap(model.handoffCopy(channel: .cook, versionID: note.id, language: "es-US"))
        }
        let one = try await saveCookCopy()
        _ = await model.markRecipient(one, recipient: "Ana", acknowledge: false, reviewedRevision: try XCTUnwrap(model.journey?.revision))
        _ = await model.change { $0.urgent[0].resolved = true }
        XCTAssertFalse(model.isCurrent(one))
        let two = try await saveCookCopy()
        let now = try XCTUnwrap(model.journey?.revision)
        let seat = MembershipSnapshot(householdID: "h", purchaserID: "owner", revision: 1, status: .active,
                                      expiresAt: at.addingTimeInterval(60), graceExpiresAt: nil, verifiedAt: at, validUntil: at.addingTimeInterval(60),
                                      seats: [.init(userID: "Ana",displayName: "A",isAdult: true)])
        func review(_ recipient: String, _ member: String, _ time: Date, _ confirmed: Bool) -> HandoffCorrection? {
            model.reviewedCorrection(two, recipient: recipient, destinationConfirmed: confirmed, privateWordingConfirmed: false,
                                     paid: seat.hasPaidAccess(for: member, now: time), reviewedRevision: now)
        }
        let delta = try XCTUnwrap(review("Ana","Ana",at,true))
        guard case let .changes(added, removed, unresolved) = delta else { return XCTFail("Expected typed changes") }
        XCTAssertEqual(added.count,1); XCTAssertEqual(removed.count,1); XCTAssertTrue(unresolved.isEmpty)
        XCTAssertTrue(removed[0].contains(pCook("Open need: review before cooking.", language: "es-US")))
        XCTAssertTrue(delta.text(current: two).contains("Por confirmar")); XCTAssertFalse(delta.text(current: two).contains("Ana"))
        for alternative in [review("Ana","different member",at,true),review("Ana","Ana",at.addingTimeInterval(61),true),
                            review("Ana","Ana",at,false),review("Other recipient","Ana",at,true)] {
            XCTAssertEqual(alternative,.full(two.fullText))
        }
        XCTAssertNil(model.reviewedCorrection(two, recipient: "Ana", destinationConfirmed: true, privateWordingConfirmed: false,
                                             paid: true, reviewedRevision: now-1))
    }

    @MainActor func testRetailerCorrectionComparesTwoFrozenVersionsAndOmitsPriceReasons() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url), at = Date()
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "Evening", commitmentsID: shopID, observedAt: at, source: "Private retailer source")
        let q = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let one = BasketLine(id: UUID(), name: "Rice", quantity: q, expectedCost: .exact(.zero))
        let two = BasketLine(id: UUID(), name: "Beans", quantity: q, expectedCost: .unknown(reason: "PRIVATE purchase reason"))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.zero)))
        _ = await model.start(from: [one], shopID: shopID, context: context)
        _ = await model.setQuote(quote, cap: nil); _ = await model.freeze()
        let old = try XCTUnwrap(model.handoffCopy(channel: .retailer, versionID: XCTUnwrap(model.frozenSnapshot?.id), language: "en-US"))
        _ = await model.markRecipient(old, recipient: "Blue store", acknowledge: false, reviewedRevision: try XCTUnwrap(model.journey?.revision))
        _ = await model.reopenDraft()
        XCTAssertFalse(model.isCurrent(old))
        let retry = await model.markRecipient(old, recipient: "Blue store", acknowledge: false, reviewedRevision: -1)
        XCTAssertTrue(retry)
        _ = await model.change { journey in
            var basket = try XCTUnwrap(journey.basket)
            _ = try basket.apply(.init(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: [.remove(one.id),.upsert(two)]), at: at)
            journey.basket = basket
        }
        _ = await model.setQuote(quote, cap: nil); _ = await model.freeze()
        let current = try XCTUnwrap(model.handoffCopy(channel: .retailer, versionID: XCTUnwrap(model.frozenSnapshot?.id), language: "en-US"))
        let rev = try XCTUnwrap(model.journey?.revision)
        let delta = try XCTUnwrap(model.reviewedCorrection(current, recipient: "Blue store", destinationConfirmed: true, privateWordingConfirmed: false, paid: true, reviewedRevision: rev))
        XCTAssertEqual(delta, .changes(added: ["Beans — 2 units"], removed: ["Rice — 2 units"], unresolved: ["Beans · Confirm the price"]))
        XCTAssertFalse(delta.text(current: current).contains("PRIVATE"))
        XCTAssertEqual(model.reviewedCorrection(current, recipient: "Other store", destinationConfirmed: true, privateWordingConfirmed: false, paid: true, reviewedRevision: rev), .full(current.fullText))
    }
    @MainActor func testCancelledCookPreviewAndSharePreserveExistingRecipientBaselines() async throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { at })
        let q = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let need = UrgentMealNeed(id: UUID(), food: "Beans", meal: "Soup", required: q,
                                 available: q, due: at.addingTimeInterval(3600), confirmedAt: at)
        let started = await model.addUrgent(need); XCTAssertTrue(started)
        func saveCurrentCopy() async throws -> HandoffCopy {
            let source = try XCTUnwrap(model.cookJourney)
            var note = PickupCookNote(id: UUID(),
                text: PickupCookProjection.text(journey: source, allocation: model.allocation, result: nil,
                    language: "en-US", at: at, timeZone: zone),
                language: "en-US", createdAt: at, revision: source.revision)
            note.reviewedHandoff = .init(pieces: PickupCookProjection.pieces(journey: source,
                allocation: model.allocation, language: "en-US", timeZone: zone),
                timeZoneID: zone.identifier, includesBudget: false, customWording: false, budget: nil)
            let saved = await model.change { $0.notes.append(note) }; XCTAssertTrue(saved)
            return try XCTUnwrap(model.handoffCopy(channel: .cook, versionID: note.id, language: "en-US"))
        }
        let original = try await saveCurrentCopy()
        for recipient in ["Ana", "Ben"] {
            let sent = await model.markRecipient(original, recipient: recipient, acknowledge: false,
                reviewedRevision: try XCTUnwrap(model.journey?.revision))
            XCTAssertTrue(sent)
        }
        let acknowledged = await model.markRecipient(original, recipient: "Ana", acknowledge: true,
            reviewedRevision: try XCTUnwrap(model.journey?.revision))
        XCTAssertTrue(acknowledged)
        let anaBaseline = try XCTUnwrap(model.journey?.lastSend(.cook, recipient: "Ana"))
        let benBaseline = try XCTUnwrap(model.journey?.lastSend(.cook, recipient: "Ben"))
        XCTAssertNotNil(anaBaseline.acknowledgedAt)
        XCTAssertNil(benBaseline.acknowledgedAt)
        XCTAssertEqual(anaBaseline.versionID, original.versionID)

        let repair = PickupRepair(id: UUID(), needID: need.id, instruction: "Warm the beans; save the broth.",
            createdAt: at, extraTripAgreed: false, repeatMealAgreed: false, elapsedMinutes: 10, due: need.due)
        let changed = await model.change { $0.repairs.append(repair) }; XCTAssertTrue(changed)
        let beforePreview = try XCTUnwrap(model.journey)
        var abandoned: String? = PickupCookProjection.text(journey: beforePreview, allocation: model.allocation,
            result: nil, language: "en-US", at: at, timeZone: zone)
        XCTAssertTrue(try XCTUnwrap(abandoned).contains(repair.instruction))
        abandoned = nil
        XCTAssertNil(abandoned)
        XCTAssertEqual(model.journey, beforePreview, "Abandoning an unsaved projection has zero mutation")

        let current = try await saveCurrentCopy()
        XCTAssertNotEqual(current.versionID, original.versionID)
        XCTAssertTrue(model.isCurrent(current))
        let beforeShare = try XCTUnwrap(model.journey)
        let correction = try XCTUnwrap(model.reviewedCorrection(current, recipient: "Ana",
            destinationConfirmed: true, privateWordingConfirmed: false, paid: true,
            reviewedRevision: beforeShare.revision))
        guard case let .changes(added, removed, _) = correction else { return XCTFail("Expected comparison with Ana's existing copy") }
        XCTAssertTrue(added.contains { $0.contains(repair.instruction) })
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(model.journey, beforeShare)
        let opened = await model.recordCookShare(.shareOpened, copy: current)
        let cancelled = await model.recordCookShare(.shareCancelled, copy: current)
        XCTAssertTrue(opened && cancelled)
        let afterShare = try XCTUnwrap(model.journey)
        let events = Array(afterShare.cookShareEvents.dropFirst(beforeShare.cookShareEvents.count))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(events.map(\.noteID), [current.versionID, current.versionID])
        XCTAssertEqual(events.map(\.action), [.shareOpened, .shareCancelled])
        XCTAssertEqual(events.map(\.occurredAt), [at, at])
        XCTAssertTrue(events.allSatisfy { $0.destination == nil })
        var expected = beforeShare
        expected.revision += 2; expected.savedAt = at; expected.cookShareEvents += events
        XCTAssertEqual(afterShare, expected, "Only the two share audit events and their revisions may change")
        XCTAssertEqual(afterShare.lastSend(.cook, recipient: "Ana"), anaBaseline)
        XCTAssertEqual(afterShare.lastSend(.cook, recipient: "Ben"), benBaseline)
        XCTAssertEqual(afterShare.notes, beforeShare.notes)
        XCTAssertEqual(model.selectedID, beforeShare.id)
        let reopened = PickupModel(databaseURL: url, clock: { at })
        await reopened.load()
        XCTAssertEqual(reopened.journey, afterShare)
        XCTAssertEqual(reopened.journey?.lastSend(.cook, recipient: "Ana"), anaBaseline)

        // Positive control: explicit recipient confirmation of the same new copy
        // advances only Ana's baseline and still does not claim acknowledgment.
        let sent = await reopened.markRecipient(current, recipient: "Ana", acknowledge: false,
            reviewedRevision: afterShare.revision)
        XCTAssertTrue(sent)
        let newBaseline = try XCTUnwrap(reopened.journey?.lastSend(.cook, recipient: "Ana"))
        XCTAssertEqual(newBaseline.versionID, current.versionID)
        XCTAssertNil(newBaseline.acknowledgedAt)
        XCTAssertEqual(reopened.journey?.lastSend(.cook, recipient: "Ben"), benBaseline)
        XCTAssertEqual(reopened.journey?.recipientSends?.filter { $0.versionID == original.versionID },
                       beforeShare.recipientSends?.filter { $0.versionID == original.versionID })
        XCTAssertEqual(reopened.journey?.recipientSends?.count, (beforeShare.recipientSends?.count ?? 0) + 1)
        var expectedSent = afterShare
        expectedSent.revision += 1; expectedSent.savedAt = at
        expectedSent.recipientSends = (afterShare.recipientSends ?? []) + [newBaseline]
        XCTAssertEqual(reopened.journey, expectedSent)
    }

}
