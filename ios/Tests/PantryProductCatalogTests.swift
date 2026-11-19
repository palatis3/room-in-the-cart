import XCTest
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
        XCTAssertTrue(line.original.contains("LOCAL-3314"))
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
