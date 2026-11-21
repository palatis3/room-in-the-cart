import XCTest
import CoreDomain
@testable import RoomInTheCart

private actor CatalogTestTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let data = Data(#"{"status":"success","product":{"code":"3017620422003","product_name_en":"Jar","product_name_es":"Frasco","quantity":"375 g","last_modified_t":1700000000,"allergens":"ignore"}}"#.utf8)
        return (data, status)
    }
}

final class PantryProductCatalogTests: XCTestCase {
    func testReviewedLabelWordingStaysWithOnePhysicalPackageAndRequiresDateConfirmation() throws {
        var batch = PantryProductBatch(workspaceID: UUID())
        XCTAssertTrue(try batch.addManual(name: "Butter beans\nBEST BEFORE DEC 2026", code: nil))
        let first = try XCTUnwrap(batch.candidates.first)
        XCTAssertEqual(first.reviewedDateWording, "BEST BEFORE DEC 2026")
        XCTAssertEqual(PrintedDateMeaning.suggested(for: try XCTUnwrap(first.reviewedDateWording)), .bestBefore)
        try batch.separate(first.id)
        XCTAssertNil(batch.candidates.last?.reviewedDateWording, "A second physical package needs its own evidence.")
        XCTAssertTrue(try batch.addManual(name: "Frijoles\nConsumo preferente DIC 2026", code: nil))
        XCTAssertEqual(batch.candidates.last?.reviewedDateWording, "Consumo preferente DIC 2026")
        XCTAssertTrue(try batch.addManual(name: "Beans\nPACKED ON JAN 2026\nBEST BEFORE DEC 2026", code: nil))
        XCTAssertNil(batch.candidates.last?.reviewedDateWording)
        XCTAssertTrue(try batch.addManual(name: "Butter beans", code: nil))
        XCTAssertNil(batch.candidates.last?.reviewedDateWording)
    }

    func testEditingUnchangedFoodRetainsTheChosenLotOnlyWhileItExists() {
        let origin = UUID(), date = Date()
        let fridge = InventoryLot(id: UUID(), foodID: UUID(), name: "Sesame", source: .manual(originID: origin, sourceID: UUID()),
                                 revision: 1, location: .fridge, openedAt: nil, unit: .count, count: .unknown,
                                 observationID: UUID(), confirmedAt: date, updatedAt: date, useFirst: false)
        var selected = VoicePantryRow(food: "sesame", original: "I used some sesame", mode: .usedSome)
        selected.showsAllLots = true
        selected.choose(fridge)
        var edited = VoicePantryRow(food: "sesame", original: "I used all sesame", mode: .all)
        XCTAssertTrue(edited.restoreSelection(from: [selected], in: [fridge]))
        XCTAssertEqual(edited.lotID, fridge.id)
        XCTAssertTrue(edited.showsAllLots)
        var other = VoicePantryRow(food: "sesame from the cupboard", original: "I used sesame from the cupboard", mode: .usedSome)
        XCTAssertFalse(other.restoreSelection(from: [selected], in: [fridge]))
        XCTAssertFalse(other.restoreSelection(from: [other], in: []))
        XCTAssertNil(other.lotID)
    }

    func testManualBarcodeCorrectionKeepsOneReviewedPackageAndRejectsAnEquivalentPhotoCode() throws {
        var batch = PantryProductBatch(workspaceID: UUID())
        XCTAssertTrue(try batch.addManual(name: "Rye crispbread", code: "LOCAL-3317"))
        batch.candidates[0].perPack = "3"
        batch.candidates[0].packages = "1"
        let original = batch.candidates[0]
        let captured = CapturedBarcode(symbology: "EAN13", value: "0200000033149")
        let photo = ScannedSource(originalText: "", uncertainLines: [], originalImageData: Data([1]), referenceJPEG: Data(), barcodes: [captured])
        XCTAssertEqual(try batch.addPhoto(photo), 1)
        batch.candidates[1].included = false
        let before = batch.candidates
        XCTAssertThrowsError(try batch.correctManualBarcode("00200000033149", for: original.id)) {
            guard case ProductBatchError.duplicateBarcode = $0 else { return XCTFail("Expected a duplicate barcode") }
        }
        XCTAssertThrowsError(try batch.correctManualBarcode(" ", for: original.id))
        XCTAssertThrowsError(try batch.correctManualBarcode("LOCAL-3314", for: before[1].id))
        XCTAssertEqual(batch.candidates, before)

        try batch.correctManualBarcode(" LOCAL-3314 ", for: original.id)
        XCTAssertFalse(try batch.addManual(name: "", code: "LOCAL-3314"))
        XCTAssertEqual(batch.candidates.count, 2)
        XCTAssertEqual(batch.candidates[0].id, original.id)
        XCTAssertEqual(batch.candidates[0].ordinal, original.ordinal)
        XCTAssertEqual(batch.candidates[1], before[1])
        let draft = try batch.draft(merchant: "Test market", purchaseDate: Date(), confirmed: true)
        XCTAssertEqual(draft.lines.count, 1)
        let line = try XCTUnwrap(draft.lines.first)
        XCTAssertEqual(line.id, original.id)
        XCTAssertEqual(line.name, "Rye crispbread")
        XCTAssertEqual(line.received, "3")
        XCTAssertEqual(line.usable, "3")
        XCTAssertEqual(line.original, "LOCAL-3314 · Rye crispbread · 1 × 3 count")
        XCTAssertEqual(batch.candidates[0].evidenceLine(unitLabel: "unidades"), "LOCAL-3314 · Rye crispbread · 1 × 3 unidades")
        XCTAssertFalse(line.original.contains("LOCAL-3317"))
    }

    func testCorrectingBarcodeDropsPreviousCatalogEvidenceAndKeepsManuallyEditedPackageValues() throws {
        var batch = PantryProductBatch(workspaceID: UUID())
        let proposal = ProductCatalogProposal(barcode: "0200000033149", name: "Suggested jar", quantity: "375 g", fetched: Date(), modified: nil)
        XCTAssertTrue(try batch.addManual(name: "", code: proposal.barcode))
        let id = batch.candidates[0].id
        batch.candidates[0].catalog = proposal
        batch.candidates[0].use(proposal)
        batch.candidates[0].name = "My jar"
        batch.candidates[0].packages = "2"
        try batch.correctManualBarcode("LOCAL-JAR", for: id)
        let row = batch.candidates[0]
        XCTAssertNil(row.catalog)
        XCTAssertNil(row.appliedCatalog)
        XCTAssertEqual(row.name, "My jar")
        XCTAssertEqual(row.packages, "2")
        XCTAssertTrue(row.perPack.isEmpty)
        XCTAssertThrowsError(try batch.draft(merchant: "Test market", purchaseDate: Date(), confirmed: true))
    }

    func testExplicitPublicLookupCoalescesByScopeAndLanguageAndSendsOnlyBarcode() async throws {
        let transport = CatalogTestTransport()
        let catalog = PantryProductCatalog(read: { try await transport.send($0) })
        let scope = UUID(), barcode = CapturedBarcode(symbology: "typed", value: "3017620422003")
        async let first = catalog.lookup(barcode, scope: scope, spanish: true)
        async let second = catalog.lookup(barcode, scope: scope, spanish: true)
        let (a,b) = try await (first,second)
        XCTAssertEqual(a, b); XCTAssertEqual(a?.name, "Frasco"); XCTAssertEqual(a?.quantity, "375 g")
        XCTAssertNotNil(a?.modified)
        _ = try await catalog.lookup(barcode, scope: scope, spanish: true)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.host, "world.openfoodfacts.org")
        XCTAssertEqual(request.url?.path, "/api/v3.6/product/3017620422003.json")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "fields", value: "code,product_name,product_name_en,product_name_es,quantity,last_modified_t")])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("hello@roominthecart.com") == true)
        let english = try await catalog.lookup(barcode, scope: scope, spanish: false)
        XCTAssertEqual(english?.name, "Jar")
        await catalog.close(scope: scope)
        _ = try await catalog.lookup(barcode, scope: scope, spanish: true)
        let afterClose = await transport.requests
        XCTAssertEqual(afterClose.count, 3)
    }

    func testUnknownAndUnavailableCatalogLeaveManualReviewAndBoundRepeatedRequests() async throws {
        let scope = UUID(), code = CapturedBarcode(symbology: "typed", value: "3017620422003")
        XCTAssertNil(PantryProductBatch.Candidate.pack("1,000 g"), "Ambiguous grouping requires manual review")
        XCTAssertNil(PantryProductBatch.Candidate.pack("2 x 375 g"))
        let missing = CatalogTestTransport(status: 404)
        let catalog = PantryProductCatalog(read: { try await missing.send($0) })
        let unknown = try await catalog.lookup(code, scope: scope, spanish: false)
        XCTAssertNil(unknown)
        _ = try await catalog.lookup(code, scope: scope, spanish: false)
        let reads = await missing.requests
        XCTAssertEqual(reads.count, 1)
        let busy = CatalogTestTransport(status: 429)
        let throttled = PantryProductCatalog(read: { try await busy.send($0) })
        for _ in 0..<2 {
            do { _ = try await throttled.lookup(code, scope: scope, spanish: false); XCTFail("Rate limit ignored") }
            catch ProductBatchError.rateLimited {}
        }
        let cappedTransport = CatalogTestTransport()
        let capped = PantryProductCatalog(read: { try await cappedTransport.send($0) })
        for _ in 0..<12 { _ = try await capped.lookup(code, scope: UUID(), spanish: false) }
        do {
            _ = try await capped.lookup(code, scope: UUID(), spanish: false)
            XCTFail("Product reads must stay within the local rolling-minute limit")
        } catch ProductBatchError.rateLimited {}
        let cappedRequests = await cappedTransport.requests
        XCTAssertEqual(cappedRequests.count, 12)
        let attempted = await busy.requests
        XCTAssertEqual(attempted.count, 1)
        let offline = PantryProductCatalog(read: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await offline.lookup(code, scope: scope, spanish: false)
            XCTFail("Disconnected transport must leave the product available for manual review")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        var batch = PantryProductBatch(workspaceID: scope)
        XCTAssertTrue(try batch.addManual(name: "My unknown product", code: "SHOP-unknown"))
        batch.candidates[0].packages = "2"; batch.candidates[0].perPack = "1"
        let draft = try batch.draft(merchant: "Shop", purchaseDate: Date(), confirmed: true)
        XCTAssertEqual(draft.lines.first?.received, "2")
        XCTAssertEqual(draft.lines.first?.name, "My unknown product")
    }
}

/// The first HTTP operation can report cancellation and still deliver buffered data after the new editor opens.
private actor SuspendedCatalogTransport {
    let firstStarted: XCTestExpectation
    let firstCancelled: XCTestExpectation
    let secondStarted: XCTestExpectation
    private var replies: [Int: CheckedContinuation<String, Never>] = [:]
    private(set) var count = 0

    init(firstStarted: XCTestExpectation, firstCancelled: XCTestExpectation, secondStarted: XCTestExpectation) {
        self.firstStarted = firstStarted
        self.firstCancelled = firstCancelled
        self.secondStarted = secondStarted
    }

    func send(_ request: URLRequest) async -> (Data, Int) {
        count += 1
        let index = count
        guard index <= 2 else { return (Data(), 500) }
        let name = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                replies[index] = continuation
                if index == 1 { firstStarted.fulfill() } else if index == 2 { secondStarted.fulfill() }
            }
        } onCancel: { [firstCancelled] in
            if index == 1 { firstCancelled.fulfill() }
        }
        return (Data(#"{"status":"success","product":{"code":"3017620422003","product_name":"\#(name)"}}"#.utf8), 200)
    }

    func complete(_ index: Int, name: String) {
        replies.removeValue(forKey: index)?.resume(returning: name)
    }
}

extension PantryProductCatalogTests {
    func testClosingEditorCancelsTransportAndLateReplyCannotReplaceReopenedLookup() async throws {
        try await checkLateReply { reader, _, _ in reader.cancel() }
    }

    func testClosingBatchScopeRejectsInFlightProposalWithoutPoisoningNextLookup() async throws {
        try await checkLateReply { _, catalog, scope in await catalog.close(scope: scope) }
    }

    private func checkLateReply(cancel: (Task<ProductCatalogProposal?, Error>, PantryProductCatalog, UUID) async -> Void) async throws {
        let started = expectation(description: "First editor sent its selected barcode")
        let cancelled = expectation(description: "Closing the editor cancelled its transport")
        let reopened = expectation(description: "Reopened editor started a separate lookup")
        let transport = SuspendedCatalogTransport(firstStarted: started, firstCancelled: cancelled, secondStarted: reopened)
        let catalog = PantryProductCatalog(read: { await transport.send($0) })
        let scope = UUID(), barcode = CapturedBarcode(symbology: "typed", value: "3017620422003")

        let original = Task { try await catalog.lookup(barcode, scope: scope, spanish: false) }
        await fulfillment(of: [started], timeout: 3)
        await cancel(original, catalog, scope)
        await fulfillment(of: [cancelled], timeout: 3)
        let current = Task { try await catalog.lookup(barcode, scope: scope, spanish: false) }
        await fulfillment(of: [reopened], timeout: 3)

        await transport.complete(2, name: "Current jar")
        await transport.complete(1, name: "Old jar")
        let fresh = try await current.value
        XCTAssertEqual(fresh?.name, "Current jar")
        do {
            _ = try await original.value
            XCTFail("A closed editor received a late proposal")
        } catch is CancellationError {}
        let cached = try await catalog.lookup(barcode, scope: scope, spanish: false)
        XCTAssertEqual(cached, fresh)
        let count = await transport.count
        XCTAssertEqual(count, 2)
    }
}

extension PantryProductCatalogTests {
    func testPackageSymbologyExpansionAndRestrictedNumbersStayPrivate() async throws {
        let upce = CapturedBarcode(symbology: "VNBarcodeSymbologyUPCE", value: "01234558")
        let upca = CapturedBarcode(symbology: "UPC-A", value: "012345000058")
        let ean = CapturedBarcode(symbology: "EAN13", value: "0012345000058")
        XCTAssertEqual(upce.packageGTIN, upca.value)
        XCTAssertEqual(upce.associationKey(retailer: ""), ean.associationKey(retailer: ""))
        XCTAssertNil(CapturedBarcode(symbology: "manual", value: upce.value).associationKey(retailer: "A"))
        XCTAssertNotEqual(CapturedBarcode(symbology: "EAN8", value: upce.value).canonicalGTIN, upce.canonicalGTIN)
        let local = CapturedBarcode(symbology: "EAN13", value: "0200000033149")
        for digits in ["9551234567896", "9581234567893"] {
            let global = CapturedBarcode(symbology: "EAN13", value: digits)
            XCTAssertEqual(global.catalogGTIN, digits)
            XCTAssertEqual(global.associationKey(retailer: "A"), global.associationKey(retailer: "B"))
        }
        for digits in ["01234565", "21234569"] {
            let short = CapturedBarcode(symbology: "EAN8", value: digits)
            let padded = CapturedBarcode(symbology: "manual", value: String(repeating: "0", count: 6) + digits)
            XCTAssertNil(short.catalogGTIN); XCTAssertNil(padded.catalogGTIN)
            XCTAssertEqual(short.associationKey(retailer: "A"), padded.associationKey(retailer: "A"))
            XCTAssertNotEqual(short.associationKey(retailer: "A"), short.associationKey(retailer: "B"))
        }
        for digits in ["9521000000018", "9781234567897", "9911000000017"] {
            let other = CapturedBarcode(symbology: "EAN13", value: digits)
            XCTAssertNil(other.catalogGTIN)
            XCTAssertNil(other.associationKey(retailer: "A"))
        }
        XCTAssertNil(local.catalogGTIN)
        XCTAssertNil(local.associationKey(retailer: " "))
        XCTAssertNotEqual(local.associationKey(retailer: "A"), local.associationKey(retailer: "B"))
        let transport = CatalogTestTransport()
        let catalog = PantryProductCatalog(read: { try await transport.send($0) })
        do {
            _ = try await catalog.lookup(local, scope: UUID(), spanish: false)
            XCTFail("Restricted-circulation identifiers must stay on device")
        } catch ProductBatchError.invalid {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(CapturedBarcode(symbology: "QR", value: "https://example.org/01/00012345000058").associationKey(retailer: "A"))
    }

    func testGS1LotAndDatesUseFieldBoundariesAndKeepPhysicalPackagesSeparate() throws {
        let gtin = "00012345000058"
        let first = CapturedBarcode(symbology: "DataMatrix", value: "]d201" + gtin + "10A15B\u{1D}1527030417270403")
        let second = CapturedBarcode(symbology: "DataMatrix", value: "(01)" + gtin + "(10)B(17)270501")
        XCTAssertNoThrow(try first.validate())
        XCTAssertEqual(first.gs1?.lot, "A15B")
        XCTAssertEqual(first.gs1?.dates.map(\.ai), ["15", "17"])
        XCTAssertEqual(first.gs1?.dates.first?.day(zone: "UTC")?.iso8601, "2027-03-04")
        XCTAssertEqual(second.gs1?.dates.last?.day(zone: "UTC")?.iso8601, "2027-05-01")
        XCTAssertNil(CapturedBarcode(symbology: "QR", value: "https://example.org/(17)270501").gs1)
        XCTAssertNil(CapturedBarcode(symbology: "GS1", value: "01" + gtin + "17270231").gs1)
        XCTAssertNil(CapturedBarcode(symbology: "EAN13", value: "0012345000058").gs1)
        XCTAssertEqual(PackageGS1("(01)" + gtin, scannerIdentifiedGS1: false)?.dates, [])
        var batch = PantryProductBatch(workspaceID: UUID())
        XCTAssertTrue(try batch.addScan(first))
        XCTAssertFalse(try batch.addScan(second))
        batch.candidates[0].packages = "2"
        try batch.separate(batch.candidates[0].id, scanned: second)
        XCTAssertEqual(batch.candidates.map(\.packages), ["1", "1"])
        XCTAssertNotEqual(batch.candidates[0].id, batch.candidates[1].id)
        XCTAssertEqual(batch.candidates.map { $0.barcode?.gs1?.lot }, ["A15B","B"])
        try batch.separate(batch.candidates[0].id)
        XCTAssertNil(batch.candidates[2].barcode?.gs1, "A new, unscanned physical batch must never inherit the first stamp.")
        XCTAssertEqual(batch.candidates[2].barcode?.canonicalGTIN, first.canonicalGTIN)
        XCTAssertThrowsError(try CapturedBarcode(symbology: "GS1", value: "01bad\u{1D}17270403").validate())
        XCTAssertEqual(PrintedPackageDate.monthDayChoices(in: "03/04").compactMap { $0.confirmed(year: "2027", zone: "UTC")?.iso8601 }, ["2027-03-04", "2027-04-03"])
        XCTAssertTrue(PrintedPackageDate.monthDayChoices(in: "03/04/2027").isEmpty)
    }

    @MainActor func testRememberedPackReopensPerOwnerAndCorrectsAndForgetsOnlyThatSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let space = UUID()
        let scope = PantryDigestScope(origin: space, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let other = PantryDigestScope(origin: space, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let code = CapturedBarcode(symbology: "UPC-A", value: "012345000058")
        let twin = CapturedBarcode(symbology: "UPC-E", value: "01234558")
        let memory = PantryPackMemory(folder: folder)
        let pack = ConfirmedPantryPack(id: UUID(), barcode: code, retailer: "", name: "Jar",
            size: Quantity(amount: try Rational(375), unit: .gram, originalLiteral: "375"), attribution: "Open Food Facts", confirmedAt: Date())
        try memory.replace(nil, with: pack, scope: scope) { true }
        let reopened = PantryPackMemory(folder: folder)
        XCTAssertEqual(try reopened.match(twin, retailer: "", scope: scope), pack)
        XCTAssertNil(try reopened.match(code, retailer: "", scope: other))
        XCTAssertNil(try reopened.match(.init(symbology: "EAN13", value: "3017620422003"), retailer: "", scope: scope))
        let revised = ConfirmedPantryPack(id: UUID(), barcode: twin, retailer: "", name: "Larger jar",
            size: Quantity(amount: try Rational(750), unit: .gram, originalLiteral: "750"), attribution: nil, confirmedAt: Date())
        XCTAssertThrowsError(try reopened.replace(nil, with: revised, scope: scope) { true })
        XCTAssertThrowsError(try reopened.replace(pack, with: revised, scope: scope) { false })
        try reopened.replace(pack, with: revised, scope: scope) { true }
        XCTAssertEqual(try memory.match(code, retailer: "", scope: scope), revised)
        var shop = ShoppingLedger()
        let preview = try PackRebuyDraft.stage(name: revised.name, count: 2, pack: revised, shop: shop, id: UUID())
        XCTAssertTrue(shop.lines.isEmpty)
        XCTAssertEqual(preview.lines.first?.quantity?.amount, try Rational(1500))
        _ = try shop.commitImport(preview)
        let line = try XCTUnwrap(shop.lines.first)
        let addition = try PackRebuyDraft.stage(name: revised.name, count: 1, pack: revised, shop: shop, id: UUID())
        let decision = [try XCTUnwrap(addition.lines.first).id: ImportResolution.addToLine(line.id)]
        _ = try shop.commitImport(addition, decisions: decision)
        _ = try shop.commitImport(addition, decisions: decision)
        XCTAssertEqual(shop.lines.count, 1)
        XCTAssertEqual(try shop.quantity(forLineID: line.id)?.amount, try Rational(2250))
        try reopened.replace(revised, with: nil, scope: scope) { true }
        XCTAssertNil(try memory.match(twin, retailer: "", scope: scope))
    }
}

extension PantryProductCatalogTests {
    @MainActor func testPackageDateReopenKeepsAnUndatedStampAndDistinguishesAnEncodedChoice() throws {
        let zone = "UTC"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryDigestScope(origin: UUID(), identity: owner), lot = UUID()
        let store = PantryPackageDateStore(folder: folder)
        let raw = "Best before 03/04"
        let actual = try PrintedPackageDate.reviewingPhoto(raw, digest: String(repeating: "b", count: 64), zone: zone)
        let april = try XCTUnwrap(PrintedPackageDate.monthDayChoices(in: raw).last)
        XCTAssertNil(april.confirmed(year: "", zone: zone))
        XCTAssertNil(april.confirmed(year: "26", zone: zone))
        XCTAssertEqual(april.confirmed(year: "2028", zone: zone)?.iso8601, "2028-04-03")
        XCTAssertNil(PrintedPackageDate.proposedDay(in: "Best before 03/04/26", zone: zone))
        XCTAssertNil(PrintedPackageDate.proposedDay(in: "Best before 7 June", zone: zone))
        try store.replace(nil, with: actual, scope: scope, lot: lot, authorized: { true })
        let undated = try XCTUnwrap(PantryPackageDateStore(folder: folder).load(scope, lot: lot))
        XCTAssertNil(undated.day)
        XCTAssertEqual(undated.originalPrintedWording, raw)
        let legacy = PrintedPackageDate(wording: raw, meaning: .bestBefore, day: april.confirmed(year: "2026", zone: zone),
            selectedPhotoText: nil, photoDigest: nil)
        try store.replace(undated, with: legacy, scope: scope, lot: lot, authorized: { true })
        let file = folder.appendingPathComponent(scope.origin.uuidString)
            .appendingPathComponent(lot.uuidString).appendingPathComponent(scope.owner + ".json")
        let legacyBytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: legacyBytes, as: UTF8.self).contains("confirmedPrintedYear"))
        let older = try XCTUnwrap(PantryPackageDateStore(folder: folder).load(scope, lot: lot))
        XCTAssertEqual(try Data(contentsOf: file), legacyBytes)
        XCTAssertTrue(older.yearNeedsReview)
        XCTAssertEqual(older.day?.iso8601, "2026-04-03")
        XCTAssertNil(older.verifiedDay)
        let proven = PrintedPackageDate(wording: raw, meaning: .bestBefore, day: older.day,
            selectedPhotoText: "Best before 03/04/2026", photoDigest: actual.photoDigest)
        try store.replace(older, with: proven, scope: scope, lot: lot, authorized: { true })
        let provenRead = try XCTUnwrap(PantryPackageDateStore(folder: folder).load(scope, lot: lot))
        XCTAssertFalse(provenRead.yearNeedsReview)
        XCTAssertEqual(provenRead.verifiedDay?.iso8601, "2026-04-03")
        var confirmed = legacy
        confirmed.confirmedPrintedYear = 2026
        try store.replace(provenRead, with: confirmed, scope: scope, lot: lot, authorized: { true })
        XCTAssertEqual(try PantryPackageDateStore(folder: folder).load(scope, lot: lot)?.verifiedDay?.iso8601, "2026-04-03")

        let code = CapturedBarcode(symbology: "GS1", value: "(01)00012345000058(10)LOT-A(17)270531")
        let encoded = try XCTUnwrap(code.gs1?.dates.first?.day(zone: zone))
        let printed = "Best before 7 June 2027"
        let choice = PrintedPackageDate(wording: printed, meaning: .expires, day: encoded,
            selectedPhotoText: printed, photoDigest: actual.photoDigest, encodedSource: code, selectedAI: "17", wordingIsPrinted: true)
        try store.replace(confirmed, with: choice, scope: scope, lot: lot, authorized: { true })
        let reopened = try XCTUnwrap(PantryPackageDateStore(folder: folder).load(scope, lot: lot))
        XCTAssertEqual(reopened.originalPrintedWording, printed)
        XCTAssertEqual(reopened.selectedPhotoText, printed)
        XCTAssertEqual(reopened.day?.iso8601, "2027-05-31")
        XCTAssertEqual(reopened.meaningLabel, pantryText("Meaning encoded in the barcode"))
        XCTAssertEqual(reopened.sourceLabel, pantryText("Encoded package date"))
        let legacyOnly = PrintedPackageDate(wording: "GS1 (17) 270531", meaning: .expires, day: encoded,
            selectedPhotoText: nil, photoDigest: nil, encodedSource: code, selectedAI: "17")
        XCTAssertNil(legacyOnly.originalPrintedWording)
    }

    @MainActor func testPackSaveRefreshAllowsOnlyProgressWhileSameAdultStillHasAccess() {
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryDigestScope(origin: UUID(), identity: owner)
        var sameOwner = true
        var current = true
        let access = PantryDigestAccess(scope: scope, snapshotIsCurrent: { current }, authorized: { sameOwner })
        XCTAssertTrue(access.authorized())
        XCTAssertFalse(access.awaitingSnapshot())
        current = false
        XCTAssertFalse(access.authorized())
        XCTAssertTrue(access.awaitingSnapshot())
        sameOwner = false
        XCTAssertFalse(access.authorized())
        XCTAssertFalse(access.awaitingSnapshot())
        current = true
        XCTAssertFalse(access.authorized())
        XCTAssertFalse(access.awaitingSnapshot())
    }

    func testDatePhotoMustAgreeWithOrdinaryUPCAndEveryKnownPhysicalLot() throws {
        let target = CapturedBarcode(symbology: "UPC-A", value: "012345000058")
        func stamp(_ gtin: String, lot: String) -> CapturedBarcode {
            CapturedBarcode(symbology: "GS1", value: "(01)" + gtin + "(10)" + lot + "(17)270422")
        }
        let a = stamp("00012345000058", lot: "A")
        let b = stamp("00012345000058", lot: "B")
        let other = stamp("03017620422003", lot: "A")
        XCTAssertFalse(PackageDateBinding.accepts(other, for: [target]))
        XCTAssertFalse(PackageDateBinding.accepts(b, for: [target, a]))
        XCTAssertTrue(PackageDateBinding.accepts(a, for: [target, a]))
        let missingLot = CapturedBarcode(symbology: "GS1", value: "(01)00012345000058(17)270422")
        XCTAssertFalse(PackageDateBinding.accepts(missingLot, for: [a]))
    }

    @MainActor func testShopRebuySeparatesKnownSiblingsAndRequiresExplicitReviewOfUnlinkedRows() throws {
        let size = Quantity(amount: try Rational(375), unit: .gram, originalLiteral: "375")
        func pack(_ amount: Quantity) -> ConfirmedPantryPack {
            .init(id: UUID(), barcode: .init(symbology: "manual", value: "012345000058"), retailer: "",
                  name: "Jar", size: amount, attribution: nil, confirmedAt: Date())
        }
        let exact = pack(size), otherVariant = pack(size)
        let larger = pack(Quantity(amount: try Rational(750), unit: .gram, originalLiteral: "750"))
        var shop = ShoppingLedger()
        let typed = try shop.addManualLine(name: "Jar", quantity: size)
        for candidate in [exact, otherVariant, larger] {
            let staged = try PackRebuyDraft.stage(name: "Jar", count: 1, pack: candidate, shop: shop, id: UUID())
            _ = try shop.commitImport(staged, decisions: [staged.lines[0].id: .addNew])
        }
        XCTAssertEqual(PackRebuyDraft.match(shop.lines[0], pack: exact, shop: shop), .unconfirmed)
        XCTAssertEqual(shop.lines[0].id, typed)
        XCTAssertFalse(PackRebuyDraft.canIncrease(shop.lines[0], pack: exact, shop: shop, confirmedUnlinked: false))
        XCTAssertTrue(PackRebuyDraft.canIncrease(shop.lines[0], pack: exact, shop: shop, confirmedUnlinked: true))
        XCTAssertEqual(PackRebuyDraft.match(shop.lines[1], pack: exact, shop: shop), .exact)
        for sibling in shop.lines.suffix(2) {
            XCTAssertEqual(PackRebuyDraft.match(sibling, pack: exact, shop: shop), .different)
            XCTAssertFalse(PackRebuyDraft.canIncrease(sibling, pack: exact, shop: shop, confirmedUnlinked: true))
        }
    }
}
