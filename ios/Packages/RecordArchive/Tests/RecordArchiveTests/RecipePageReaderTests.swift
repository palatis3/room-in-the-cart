import XCTest
@testable import RecordArchive

final class RecipePageReaderTests: XCTestCase {
    func testSelectedPagePreservesSourceAfterRedirectAndReadsOnlyInlineRecipeData() async throws {
        let html = #"""
        <html><body><script type="text/javascript">ordinary script</script>
        <script type="application/ld+json" src="other.json"></script>
        <script type="application/ld+json">{"@graph":[{"@type":"Person"},{"@type":"Recipe","name":"Arroz","recipeYield":["4","4 porciones"],"recipeIngredient":["2 tazas de arroz"]}]}</script>
        <script type="application/ld+json">[{"@type":"Recipe","name":"Sopa"}]</script></body></html>
        """#
        var requested: [String] = []
        let data = try await RecipePageReader.document(at: "https://recipes.example.org/start") { page, _ in
            requested.append(page.path)
            if page.path == "/start" {
                return try RecipePageResponse(Data("HTTP/1.1 301 Moved\r\nLocation: /arroz#recipe\r\n\r\n".utf8))
            }
            return try RecipePageResponse(Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" + html).utf8))
        }
        let report = try RecipeImporter.stage(data)
        XCTAssertEqual(requested, ["/start", "/arroz"])
        XCTAssertEqual(report.recipes.map(\.title), ["Arroz", "Sopa"])
        XCTAssertEqual(report.recipes.map(\.sourceURL), Array(repeating: "https://recipes.example.org/arroz", count: 2))
        XCTAssertEqual(report.recipes.first?.yieldText, "4\n4 porciones")
        XCTAssertEqual(report.recipes.first?.missingFields, [.instructions])
    }

    func testOfflineSourceKeepsItsAddressAndPartialHTMLPreservesThePageTitle() throws {
        let address = "https://recipes.example.org/frijoles#ingredients"
        let offline = try RecipePageReader.partialRecipe(at: address)
        XCTAssertEqual(offline.sourceURL, address)
        XCTAssertEqual(offline.missingFields, [.servings, .ingredients, .instructions])
        XCTAssertThrowsError(try RecipePageReader.partialRecipe(at: "https://name:secret@example.org/"))
        let source = try XCTUnwrap(URL(string: address))
        let html = Data("<html><head><title>Frijoles &amp; arroz</title></head><body></body></html>".utf8)
        let report = try RecipeImporter.stage(RecipePageReader.document(body: html, contentType: "text/html", source: source))
        XCTAssertEqual(report.recipes, [ImportedRecipe(title: "Frijoles & arroz", sourceURL: address)])
        let partial = Data(#"<html><head><title>Sopa</title><script type="application/ld+json">{"@type":"Recipe","recipeIngredient":["1 kg de papa"]}</script></head></html>"#.utf8)
        let partialReport = try RecipeImporter.stage(RecipePageReader.document(body: partial, contentType: "text/html", source: source))
        XCTAssertEqual(partialReport.recipes, [ImportedRecipe(title: "Sopa", ingredients: ["1 kg de papa"], sourceURL: address)])
    }

    func testRedirectValidationPrecedesAnotherRequestAndStopsAtThreeHops() async throws {
        for (target, expectedRequests) in [("http://recipes.example.org/soup", 1), ("/next", 4)] {
            var requests = 0
            do {
                _ = try await RecipePageReader.document(at: "https://recipes.example.org/start") { _, _ in
                    requests += 1
                    return try RecipePageResponse(Data(("HTTP/1.1 302 Found\r\nLocation: " + target + "\r\n\r\n").utf8))
                }
                XCTFail("The destination must be safe and reached within the redirect limit")
            } catch { XCTAssertEqual(error as? ArchiveError, .invalidRecipe) }
            XCTAssertEqual(requests, expectedRequests)
        }
    }

    func testOnlyPublicHTTPSAndBoundedResponseFormats() throws {
        for address in ["http://recipes.example.org/x", "https://localhost/x", "https://127.0.0.1/x", "https://recipes.example.org:7443/x"] {
            XCTAssertThrowsError(try RecipePageReader.checkedURL(XCTUnwrap(URL(string: address))))
        }
        XCTAssertFalse(RecipePageConnection.publicIPv4(Data([10, 0, 0, 1])))
        XCTAssertFalse(RecipePageConnection.publicIPv6(Data(repeating: 0, count: 16)))
        XCTAssertTrue(RecipePageConnection.publicIPv4(Data([1, 1, 1, 1])))
        let response = try RecipePageResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nsoup\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(response.body, Data("soup".utf8))
        XCTAssertThrowsError(try RecipePageResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nsoup".utf8)))
        let source = try XCTUnwrap(URL(string: "https://recipes.example.org/soup"))
        XCTAssertThrowsError(try RecipePageReader.document(body: Data("A scanned page".utf8), contentType: "application/pdf", source: source))
        XCTAssertThrowsError(try RecipePageReader.document(body: Data("<p>No recipe data</p>".utf8), contentType: "text/html", source: source))
    }
}
