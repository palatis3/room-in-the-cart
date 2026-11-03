import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

final class LedgerPackBridgeTests: XCTestCase {
        private struct LedgerDocumentFixture: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
    @MainActor func testArchiveScopePreservesOnlySelectedShopPackEvidenceAndEarlierLedgerFilesRemainReadable() async throws {
        let (ledger, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shop = try XCTUnwrap(ledger.shop), line = try XCTUnwrap(shop.lines.first?.id)
        try saved(try await packReview(ledger, line: line).save(offerID: "b", ledger: ledger))
        var other = ShoppingLedger(title: "Other shop")
        let otherLine = try other.addManualLine(name: "Rice", quantity: q(2))
        let requirement = try LedgerPackRequirement.review(shop: other, lineID: otherLine)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity,
            offerA: PackOffer(id: "a", label: "Rice one", usableQuantity: q(1), price: Money(minorUnits: 100)),
            offerB: PackOffer(id: "b", label: "Rice two", usableQuantity: q(2), price: Money(minorUnits: 150)))
        let otherSelection = try LedgerPackSelection(workspaceID: XCTUnwrap(ledger.sourceWorkspaceID), shop: other, lineID: otherLine, request: request,
            selectedOfferID: "b", at: Date(), source: "Other shelf")
        var workspace = ledger.workspace
        workspace.shops.append(other); workspace.packSelections.append(otherSelection)
        let scoped = try RecordsNativeCodec.ledgerScope(workspace, shop: shop)
        XCTAssertEqual(scoped.packSelections, ledger.workspace.packSelections)
        let data = try RecordsNativeCodec.canonical(LedgerDocumentFixture(formatVersion: 1, workspace: scoped))
        var record = ArchiveRecord(id: shop.id.uuidString, origin: "ledger/fixture", revision: ArchiveCodec.digest(data), kind: .ledger,
            title: shop.title, savedAtMilliseconds: 100, nativePayload: data)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try XCTUnwrap(object["workspace"] as? [String: Any])
        body.removeValue(forKey: "packSelections"); object["workspace"] = body
        record.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        XCTAssertTrue(try RecordsNativeCodec.ledger(XCTUnwrap(record.nativePayload)).packSelections.isEmpty)
        body["canApplyImportedPack"] = true; object["workspace"] = body
        record.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(record))
    }
    @MainActor func testEarlierPickupArchiveDefaultsPackEvidenceWithoutAcceptingExtraAuthority() async throws {
        let (ledger, pickup, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let review = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil)
        try saved(try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup))
        let value = try XCTUnwrap(pickup.journey)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: RecordsNativeCodec.canonical(value)) as? [String: Any])
        object.removeValue(forKey: "ledgerPackSelections")
        let earlier = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        var record = ArchiveRecord(id: value.id.uuidString, origin: "pickups/fixture", revision: ArchiveCodec.digest(earlier), kind: .pickup,
            title: "Pickup", savedAtMilliseconds: 100, nativePayload: earlier)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        XCTAssertTrue(try RecordsNativeCodec.pickup(earlier).ledgerPackSelections.isEmpty)
        object["sharedCommitAuthorized"] = true
        record.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(record))
    }
        @MainActor func testPackChoiceKeepsSavedCheckoutUntilExplicitReviewThenSuppliesWholePacksWithoutInventingDemand() async throws {
        let (ledger, pickup, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(ledger.shop), line = try XCTUnwrap(source.lines.first)
        let original = try LedgerCheckoutAdapter.review(shop: source, workspaceRevision: ledger.revision, previous: nil)
        try saved(try await LedgerCheckoutAdapter.apply(original, ledger: ledger, pickup: pickup))
        try saved(await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: original.context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 900)))), cap: original.cap))
        try saved(await pickup.freeze())
        let before = try XCTUnwrap(pickup.journey), snapshot = try XCTUnwrap(pickup.frozenSnapshot)
        let review = try packReview(ledger, line: line.id)
        try saved(try await review.save(offerID: "b", ledger: ledger))
        XCTAssertEqual(ledger.shop, source)
        XCTAssertEqual(pickup.journey, before, "Saving ledger evidence does not silently mutate the separate checkout store")
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: pickup.journey,
            packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        XCTAssertTrue(checkout.needsApplication)
        XCTAssertEqual(checkout.lines.first?.quantity.amount, try Rational(12))
        XCTAssertEqual(checkout.lines.first?.expectedCost, .exact(Money(minorUnits: 400)))
        XCTAssertEqual(try checkout.needs.reduce(Rational.zero) { try $0.adding($1.amount.amount) }, try Rational(10))
        XCTAssertEqual(checkout.needs.first { $0.priority == .protected }?.amount.amount, try Rational(2))
        try saved(try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup))
        XCTAssertNil(pickup.journey?.quote)
        XCTAssertNil(pickup.result)
        XCTAssertEqual(pickup.journey?.basket?.snapshots.first, snapshot)
        XCTAssertEqual(pickup.journey?.basket?.phase, .draft)
        XCTAssertEqual(pickup.journey?.ledgerPackSelections, ledger.workspace.packSelections)
        let frozenText = snapshot.revision.lines.first?.quantity.amount
        XCTAssertEqual(frozenText, try Rational(10))
    }
    @MainActor func testExactSelectionRetryAndUnchangedCheckoutReviewDoNotCreateRevisionsOrClearFreshQuote() async throws {
        let (ledger, pickup, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = try XCTUnwrap(ledger.shop?.lines.first?.id)
        let review = try packReview(ledger, line: line)
        try saved(try await review.save(offerID: "b", ledger: ledger))
        let revision = ledger.revision
        try saved(try await review.save(offerID: "b", ledger: ledger))
        XCTAssertEqual(ledger.revision, revision)
        XCTAssertEqual(ledger.workspace.packSelections.count, 1)
        do { _ = try await review.save(offerID: "a", ledger: ledger); XCTFail("The same reviewed operation cannot choose a different result on retry") }
        catch { XCTAssertEqual(error as? LedgerPackError, .operationConflict) }
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil,
            packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        try saved(try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: checkout.context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 640))))
        try saved(await pickup.setQuote(quote, cap: checkout.cap))
        let unchanged = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: pickup.journey,
            packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        XCTAssertFalse(unchanged.needsApplication)
        let prior = pickup.journey
        try saved(try await LedgerCheckoutAdapter.apply(unchanged, ledger: ledger, pickup: pickup))
        try saved(try await LedgerCheckoutAdapter.apply(unchanged, ledger: ledger, pickup: pickup))
        XCTAssertEqual(pickup.journey, prior)
        XCTAssertEqual(pickup.journey?.quote, quote)
    }
    @MainActor func testChangedSourceRejectsReviewAndStalePackCostCannotLeakIntoUnchangedQuantity() async throws {
        let (ledger, pickup, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shop = try XCTUnwrap(ledger.shop), line = try XCTUnwrap(shop.lines.first?.id)
        let review = try packReview(ledger, line: line, packSize: 5)
        try saved(try await review.save(offerID: "b", ledger: ledger))
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil,
            packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        try saved(try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup))
        let stale = try packReview(ledger, line: line)
        try saved(await ledger.editShop(key: "new-source-note", shopID: shop.id) { try $0.updateLine(lineID: line, name: "Wraps", notes: "Recheck sesame exclusion", aisle: "") })
        do { _ = try await stale.save(offerID: "b", ledger: ledger); XCTFail("A source edit invalidates the preview") }
        catch { XCTAssertEqual(error as? LedgerPackError, .staleSource) }
        let changed = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: pickup.journey,
            packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        XCTAssertTrue(changed.packSelections.isEmpty)
        XCTAssertEqual(changed.lines.first?.quantity.amount, try Rational(10))
        guard case .unknown = changed.lines[0].expectedCost else { return XCTFail("An old selected pack price must be rechecked even when its purchased quantity matched demand") }
        XCTAssertEqual(ledger.workspace.packSelections.count, 1)
    }
    @MainActor func testPackEvidenceRestartAndPlacedOrderBoundaryRemainDurable() async throws {
        let (ledger, pickup, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shop = try XCTUnwrap(ledger.shop), line = try XCTUnwrap(shop.lines.first?.id)
        try saved(try await packReview(ledger, line: line).save(offerID: "b", ledger: ledger))
        let reopened = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await reopened.open()
        XCTAssertEqual(reopened.workspace.packSelections, ledger.workspace.packSelections)
        let review = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(reopened.shop), workspaceRevision: reopened.revision, previous: nil,
            packSelections: reopened.workspace.packSelections, workspaceID: reopened.sourceWorkspaceID)
        try saved(try await LedgerCheckoutAdapter.apply(review, ledger: reopened, pickup: pickup))
        try saved(await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: review.context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 400)))), cap: nil))
        try saved(await pickup.freeze()); try saved(await pickup.reportPlaced())
        let placed = try XCTUnwrap(pickup.journey)
        let changed = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(reopened.shop), workspaceRevision: reopened.revision, previous: placed,
            packSelections: reopened.workspace.packSelections, workspaceID: reopened.sourceWorkspaceID)
        do { _ = try await LedgerCheckoutAdapter.apply(changed, ledger: reopened, pickup: pickup); XCTFail("Reported placement cannot be amended through a local pack review") }
        catch { XCTAssertEqual(error as? LedgerCheckoutError, .placedOrder) }
        XCTAssertEqual(pickup.journey, placed)
        let reopenedPickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await reopenedPickup.load()
        XCTAssertEqual(reopenedPickup.journey?.ledgerPackSelections, placed.ledgerPackSelections)
        XCTAssertEqual(reopenedPickup.journey?.pickup?.orderLines.first?.ordered.amount, try Rational(12))
    }
    @MainActor private func fixture() async throws -> (LedgerModel, PickupModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        try saved(await ledger.startShop(title: "Pack review pickup"))
        let id = try XCTUnwrap(ledger.shop?.id)
        try saved(await ledger.editShop(key: "needs", shopID: id) { shop in
            try shop.updateBasis(ShopBasis(branch: "Main branch", mode: .pickup,
                slot: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/New_York"))
            let line = try shop.addManualLine(name: "Wraps", quantity: self.q(10))
            let supply = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
            try shop.addProtectedNeed(name: "Wraps", quantity: self.q(2), purpose: "Lunch", within: supply)
        })
        return (ledger, pickup, directory)
    }
    @MainActor private func packReview(_ ledger: LedgerModel, line: UUID, packSize: Int64 = 6) throws -> LedgerPackReview {
        try LedgerPackReview.prepare(ledger: ledger, shopID: XCTUnwrap(ledger.shop?.id), lineID: line,
            offerA: PackOffer(id: "a", label: "Eight pack", usableQuantity: q(8), price: Money(minorUnits: 300)),
            offerB: PackOffer(id: "b", label: "Chosen pack", usableQuantity: q(packSize), price: Money(minorUnits: 200)),
            itemCap: nil, at: Date(timeIntervalSince1970: 1_800_000_000), source: "Reviewed store shelf")
    }
    private func saved(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(value, file: file, line: line)
        if !value { throw CocoaError(.fileWriteUnknown) }
    }
    private func q(_ amount: Int64) -> Quantity { Quantity(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }
}
