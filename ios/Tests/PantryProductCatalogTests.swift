import XCTest
@testable import RoomInTheCart

private actor CatalogTestTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let data = Data(#"{"status":1,"product":{"code":"3017620422003","product_name_en":"Jar","product_name_es":"Frasco","quantity":"375 g","last_modified_t":1700000000,"allergens":"ignore"}}"#.utf8)
        return (data, status)
    }
}

final class PantryProductCatalogTests: XCTestCase {
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
        XCTAssertEqual(request.url?.path, "/api/v2/product/3017620422003.json")
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
        let attempted = await busy.requests
        XCTAssertEqual(attempted.count, 1)
        var batch = PantryProductBatch(workspaceID: scope)
        XCTAssertTrue(try batch.addManual(name: "My unknown product", code: "SHOP-unknown"))
        batch.candidates[0].packages = "2"; batch.candidates[0].perPack = "1"
        let draft = try batch.draft(merchant: "Shop", purchaseDate: Date(), confirmed: true)
        XCTAssertEqual(draft.lines.first?.received, "2")
        XCTAssertEqual(draft.lines.first?.name, "My unknown product")
    }
}
