import Foundation
import libxml2

/// Reads the selected public HTTPS page and returns ordinary Recipe JSON-LD for the existing review.
public enum RecipePageReader {
    static let maximumBody = 2 * 1024 * 1024
    static let maximumHeader = 16 * 1024

    public static func document(at address: String) async throws -> Data {
        try await document(at: address) { try await RecipePageConnection().load($0, deadline: $1) }
    }

    static func document(at address: String, fetch: (URLComponents, DispatchTime) async throws -> RecipePageResponse) async throws -> Data {
        guard let initial = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ArchiveError.invalidRecipe }
        var destination = initial
        let deadline = DispatchTime.now() + .seconds(18)
        for hop in 0...3 {
            try Task.checkCancellation()
            let page = try checkedURL(destination)
            let response = try await fetch(page, deadline)
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard hop < 3, let location = response.headers["location"],
                      let next = URL(string: location, relativeTo: page.url)?.absoluteURL else { throw ArchiveError.invalidRecipe }
                destination = next
                continue
            }
            guard response.status == 200, let source = page.url, let contentType = response.headers["content-type"] else { throw ArchiveError.invalidRecipe }
            return try document(body: response.body, contentType: contentType, source: source)
        }
        throw ArchiveError.invalidRecipe
    }

    /// An offline review can keep the selected source even when its page is unavailable.
    public static func partialRecipe(at address: String) throws -> ImportedRecipe {
        let literal = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: literal) else { throw ArchiveError.invalidRecipe }
        let page = try checkedURL(url)
        guard let host = page.host else { throw ArchiveError.invalidRecipe }
        return try ImportedRecipe(title: host, sourceURL: literal).validated()
    }

    static func checkedURL(_ url: URL) throws -> URLComponents {
        guard url.absoluteString.utf8.count <= 4096, var page = URLComponents(url: url, resolvingAgainstBaseURL: true),
              page.scheme?.lowercased() == "https", page.user == nil, page.password == nil,
              page.port == nil || page.port == 443, let host = page.host?.lowercased(), host.utf8.count <= 253 else {
            throw ArchiveError.invalidRecipe
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let letter: (UInt8) -> Bool = { (97...122).contains($0) }
        guard labels.count > 1, let suffix = labels.last, suffix.utf8.contains(where: letter),
              !["local", "localhost", "internal", "home", "lan", "onion", "invalid", "test"].contains(String(suffix)),
              !host.hasSuffix(".home.arpa"), labels.allSatisfy({ part in
                  (1...63).contains(part.utf8.count) && part.first != "-" && part.last != "-" &&
                      part.utf8.allSatisfy { letter($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw ArchiveError.invalidRecipe }
        page.host = host
        page.fragment = nil
        guard page.url != nil else { throw ArchiveError.invalidRecipe }
        return page
    }

    static func document(body: Data, contentType: String, source: URL) throws -> Data {
        guard !body.isEmpty, body.count <= maximumBody else { throw ArchiveError.tooLarge }
        let mime = contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        let scripts: [Data]
        var pageTitle: String?
        switch mime {
        case "text/html", "application/xhtml+xml": (scripts, pageTitle) = try inlineScripts(body)
        case "application/ld+json", "application/json": scripts = [body]
        default: throw ArchiveError.invalidRecipe
        }
        var nodes: [[String: Any]] = []
        for script in scripts {
            // One unrelated invalid script must not hide other recipes on the page.
            guard (try? ArchiveCodec.preflight(script)) != nil,
                  let json = try? JSONSerialization.jsonObject(with: script) else { continue }
            func append(_ value: Any) throws {
                if let array = value as? [Any] {
                    for child in array { try append(child) }
                } else if let object = value as? [String: Any] {
                    let types = object["@type"] as? [String] ?? (object["@type"] as? String).map { [$0] } ?? []
                    if types.contains(where: { ["Recipe", "https://schema.org/Recipe", "http://schema.org/Recipe"].contains($0) }) {
                        guard nodes.count < ArchiveCodec.maximumRecords else { throw ArchiveError.tooLarge }
                        var recipe = object
                        if let pageTitle, (recipe["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            recipe["name"] = pageTitle
                        }
                        recipe.removeValue(forKey: "@graph") // Linked nodes are visited separately.
                        recipe["url"] = source.absoluteString
                        // Publishers often supply a short yield plus a human-readable alternative.
                        // Keep the full text without choosing a numeric serving count.
                        if let yields = recipe["recipeYield"] as? [String] {
                            recipe["recipeYield"] = yields.joined(separator: "\n")
                        }
                        nodes.append(recipe)
                    }
                    if let graph = object["@graph"] as? [Any] { try append(graph) }
                }
            }
            try append(json)
        }
        if nodes.isEmpty, let pageTitle {
            nodes.append(["@type": "Recipe", "name": pageTitle, "url": source.absoluteString])
        }
        guard !nodes.isEmpty else { throw ArchiveError.invalidRecipe }
        let data = try JSONSerialization.data(withJSONObject: nodes)
        guard data.count <= ArchiveCodec.maximumFileBytes else { throw ArchiveError.tooLarge }
        return data
    }

    private static func inlineScripts(_ body: Data) throws -> (scripts: [Data], title: String?) {
        guard String(data: body, encoding: .utf8) != nil else { throw ArchiveError.invalidRecipe }
        // Parse an inert memory document. No browser, DTD loading, scripts, styles, frames or images.
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        let document = body.withUnsafeBytes { buffer in
            htmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, "UTF-8", Int32(options))
        }
        guard let document else { throw ArchiveError.invalidRecipe }
        defer { xmlFreeDoc(document) }
        guard let context = xmlXPathNewContext(document) else { throw ArchiveError.invalidRecipe }
        defer { xmlXPathFreeContext(context) }
        var title: String?
        if let result = xmlXPathEvalExpression("string(/html/head/title[1])", context) {
            defer { xmlXPathFreeObject(result) }
            if let value = result.pointee.stringval, xmlStrlen(value) <= 4096 {
                let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { title = text }
            }
        }
        guard let matches = xmlXPathEvalExpression("//script[@type and not(@src)]", context) else { throw ArchiveError.invalidRecipe }
        defer { xmlXPathFreeObject(matches) }
        guard let set = matches.pointee.nodesetval, let table = set.pointee.nodeTab else { return ([], title) }
        var scripts: [Data] = []
        for i in 0..<Int(set.pointee.nodeNr) {
            guard let node = table[i], let type = xmlGetProp(node, "type") else { continue }
            defer { xmlFree(type) }
            guard String(cString: type).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/ld+json" else { continue }
            guard scripts.count < 64 else { throw ArchiveError.tooLarge }
            guard let text = xmlNodeGetContent(node) else { continue }
            defer { xmlFree(text) }
            scripts.append(Data(bytes: text, count: Int(xmlStrlen(text))))
        }
        return (scripts, title)
    }
}
