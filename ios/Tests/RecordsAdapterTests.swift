import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

final class RecordsAdapterTests: XCTestCase {
    private struct CollectionFixture: Codable { let flexible: Set<UUID>; let frozenQuotes: [UUID: CheckoutQuote] }
    private struct LedgerFixture: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func comparison() throws -> ArchiveRecord {
        var draft = ComparisonDraft()
        draft.item = "Arroz"; draft.needed = "2"; draft.unit = .count
        draft.aLabel = "Original A"; draft.aQuantity = "1"; draft.aPrice = "3.49"
        draft.bLabel = "Original B"; draft.bQuantity = "2"; draft.bPrice = "5.00"
        let request = try ComparisonModel(draft: draft).request()
        let payload = SavedPayload(draft: draft, calculationVersion: SavedPayload.currentCalculationVersion,
            normalizedRequest: request, answer: try PackComparison.evaluate(request), roundingPolicy: SavedPayload.currentRoundingPolicy)
        let data = try RecordsNativeCodec.canonical(payload)
        return ArchiveRecord(id: draft.id.uuidString, origin: "comparisons/fixture", revision: ArchiveCodec.digest(data),
            kind: .comparison, title: draft.item, savedAtMilliseconds: 1_800_000_000_000,
            helperLines: [HelperLine(label: draft.item, originalAmount: draft.needed, originalUnit: "count")], nativePayload: data)
    }
    @MainActor func testComparisonNativeRoundTripAndNestedAuthorityFieldRejection() throws {
        let record = try comparison()
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let payload = try RecordsNativeCodec.comparison(XCTUnwrap(record.nativePayload))
        XCTAssertEqual(payload.draft.aPrice, "3.49")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(record.nativePayload)) as? [String: Any])
        var draft = try XCTUnwrap(object["draft"] as? [String: Any])
        draft["membershipToken"] = "never accepted"
        object["draft"] = draft
        var altered = record
        altered.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(altered)) { XCTAssertEqual($0 as? ArchiveError, .unsupportedRecord) }
    }
    @MainActor func testLedgerCanonicalRoundTripPreservesOriginalImportAndUUIDDecisionMap() throws {
        var shop = ShoppingLedger(title: "Tuesday")
        let original = "2 rice\nsalt to taste"
        let preview = shop.stageImport(text: original, source: .paste)
        let decisions = Dictionary(uniqueKeysWithValues: preview.lines.map { ($0.id, ImportResolution.addNew) })
        _ = try shop.commitImport(preview, decisions: decisions, at: Date(timeIntervalSince1970: 100))
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        let bytes = try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: workspace))
        let decoded = try RecordsNativeCodec.ledger(bytes)
        XCTAssertEqual(decoded.shops.first?.importBatches.first?.originalText, original)
        XCTAssertEqual(decoded.shops.first?.importBatches.first?.decisions, decisions)
        XCTAssertEqual(try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: decoded)), bytes)
        let record = ArchiveRecord(id: shop.id.uuidString, origin: "ledger/fixture", revision: ArchiveCodec.digest(bytes), kind: .ledger,
            title: shop.title, savedAtMilliseconds: 100_000, nativePayload: bytes)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
    }
    @MainActor func testPickupCanonicalRoundTripOrdersSetAndUUIDQuoteMapWithoutChangingValues() throws {
        let id = UUID(), lineID = UUID(), date = Date(timeIntervalSince1970: 100)
        let quantity = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2 paquetes")
        let line = BasketLine(id: lineID, name: "Arroz", quantity: quantity, expectedCost: .unknown(reason: "Not quoted"))
        let basket = try BasketPlan(id: id, revisionID: UUID(), lines: [line], createdAt: date)
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "5 PM", commitmentsID: id, observedAt: date, source: "Manual")
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 500))))
        var value = PickupJourney(id: id, savedAt: date)
        value.basket = basket; value.context = context; value.quote = quote; value.quotedRevisionID = basket.current.id
        value.frozenQuotes = [basket.current.id: quote]; value.flexible = [lineID]
        let bytes = try RecordsNativeCodec.canonical(value)
        let decoded = try RecordsNativeCodec.pickup(bytes)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(try RecordsNativeCodec.canonical(decoded), bytes)
        XCTAssertEqual(decoded.basket?.current.lines.first?.quantity.originalLiteral, "2 paquetes")
        let record = ArchiveRecord(id: id.uuidString, origin: "pickups/fixture", revision: ArchiveCodec.digest(bytes), kind: .pickup,
            title: "Arroz", savedAtMilliseconds: 100_000, nativePayload: bytes)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let other = UUID()
        let left = CollectionFixture(flexible: [id, other], frozenQuotes: [id: quote, other: quote])
        let right = CollectionFixture(flexible: [other, id], frozenQuotes: [other: quote, id: quote])
        XCTAssertEqual(try RecordsNativeCodec.canonical(left), try RecordsNativeCodec.canonical(right))
        let collectionBytes = try RecordsNativeCodec.canonical(left)
        let reloaded = try JSONDecoder().decode(CollectionFixture.self, from: collectionBytes)
        XCTAssertEqual(try RecordsNativeCodec.canonical(reloaded), collectionBytes)
    }
    @MainActor func testHelperExportDropsNativeFinanceAndPersonalExportRequiresWorkingKey() async throws {
        let record = try comparison(), registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
        let model = RecordsToolsModel(registry: registry, snapshot: { [record] }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh(); model.selectAll()
        await model.prepareExport(.helperJSON)
        let helper = try ArchiveCodec.decode(XCTUnwrap(model.preparedDocument).data)
        XCTAssertNil(helper.payload.records.first?.nativePayload)
        XCTAssertEqual(helper.payload.records.first?.helperLines.first?.label, "Arroz")
        XCTAssertFalse(String(decoding: try ArchiveCodec.encode(helper), as: UTF8.self).contains("3.49"))
        await model.prepareExport(.encryptedRecovery)
        XCTAssertNil(model.preparedDocument); XCTAssertEqual(model.error, .invalidKey)
        model.generateRecoveryKey()
        await model.prepareExport(.encryptedRecovery)
        let encrypted = try XCTUnwrap(model.preparedDocument).data
        XCTAssertEqual(try EncryptedArchive.open(encrypted, key: model.recoveryKey).payload.records, [record])
    }
    @MainActor func testSourceErasureBetweenSelectionAndExportCannotExportCachedPrivateData() async throws {
        let record = try comparison(), registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
        var sources = [record]
        let model = RecordsToolsModel(registry: registry, snapshot: { sources }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh(); model.selectAll()
        sources = []
        await model.prepareExport(.ownerText)
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(model.error, .unavailable)
        XCTAssertTrue(model.currentRecords.isEmpty)
    }
    @MainActor func testUnsupportedNativeImportStagesNothingAndPreservesRegistryBytes() async throws {
        let directory = try temporaryDirectory(), registry = try RecoveryRegistry(url: directory.appendingPathComponent("manifest.json"))
        let record = try comparison()
        let initial = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "fixture", revision: "first")
        _ = try await registry.apply(registry.review(initial))
        let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        var corrupt = record
        corrupt.id = UUID().uuidString
        let archive = try ArchiveCodec.make(records: [corrupt], kind: .personalRecovery, origin: "fixture", revision: "bad")
        let file = directory.appendingPathComponent("bad.json")
        try ArchiveCodec.encode(archive).write(to: file)
        let model = RecordsToolsModel(registry: registry, snapshot: { [record] }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.importFile(file, recipes: false)
        XCTAssertNil(model.review)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before)
    }
}
