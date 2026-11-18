import Foundation

struct ProductCatalogProposal: Equatable, Sendable {
    let barcode: String
    let name: String?
    let quantity: String?
    let fetched: Date
    let modified: Date?
    var source: URL { URL(string: "https://world.openfoodfacts.org/product/" + barcode)! }
    var attribution: String {
        ["Open Food Facts", name, quantity, source.absoluteString, fetched.ISO8601Format()].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Only an explicitly selected GTIN goes on the wire. Cookies, redirects, response caching and writes are disabled.
private final class CatalogNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor PantryProductCatalog {
    typealias Read = @Sendable (URLRequest) async throws -> (Data, Int)
    static let shared = PantryProductCatalog()
    private struct Key: Hashable { let scope: UUID; let code: String; let spanish: Bool }
    private struct Entry { let time: Date; let value: ProductCatalogProposal? }
    private struct Pending { let id: UUID; let task: Task<ProductCatalogProposal?, Error> }
    private struct Response: Decodable {
        let status: String
        let code: String?
        let product: Product?
        struct Product: Decodable {
            let code: String?
            let product_name: String?
            let product_name_en: String?
            let product_name_es: String?
            let quantity: String?
            let last_modified_t: Int?
        }
    }
    private let read: Read
    private let now: @Sendable () -> Date
    private var cache: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    private var requests: [Date] = []
    private var backoff = Date.distantPast

    init(now: @escaping @Sendable () -> Date = { Date() }, read: Read? = nil) {
        self.now = now
        self.read = read ?? Self.request
    }

    func close(scope: UUID) {
        cache = cache.filter { $0.key.scope != scope }
        for key in pending.keys.filter({ $0.scope == scope }) { pending.removeValue(forKey: key)?.task.cancel() }
    }

    func lookup(_ barcode: CapturedBarcode, scope: UUID, spanish: Bool) async throws -> ProductCatalogProposal? {
        guard barcode.validGTIN else { throw ProductBatchError.invalid }
        let code = barcode.value
        let key = Key(scope: scope, code: String(repeating: "0", count: 14 - code.count) + code, spanish: spanish)
        let instant = now()
        if let existing = cache[key], instant >= existing.time, instant.timeIntervalSince(existing.time) < 86_400 { return existing.value }
        if let existing = pending[key] { return try await existing.task.value }
        requests.removeAll { instant.timeIntervalSince($0) >= 60 }
        guard instant >= backoff, requests.count < 12 else { throw ProductBatchError.rateLimited }
        requests.append(instant)
        var url = URLComponents(string: "https://world.openfoodfacts.org/api/v3.6/product/" + code + ".json")!
        url.queryItems = [URLQueryItem(name: "fields", value: "code,product_name,product_name_en,product_name_es,quantity,last_modified_t")]
        var req = URLRequest(url: url.url!, timeoutInterval: 8)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        req.setValue("RoomInTheCart/" + version + " (hello@roominthecart.com)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = Task { [read] () -> ProductCatalogProposal? in
            let (data, status) = try await read(req)
            try Task.checkCancellation()
            if status == 404 { return nil }
            if status == 429 || status == 503 { throw ProductBatchError.rateLimited }
            guard status == 200, data.count <= 32_768 else { throw ProductBatchError.lookupUnavailable }
            let value = try JSONDecoder().decode(Response.self, from: data)
            guard ["success", "success_with_warnings"].contains(value.status), let row = value.product, let responseCode = row.code ?? value.code,
                  CapturedBarcode(symbology: "catalog", value: responseCode).validGTIN,
                  code.drop(while: { $0 == "0" }) == responseCode.drop(while: { $0 == "0" }) else {
                throw ProductBatchError.lookupUnavailable
            }
            func bounded(_ value: String?) -> String? {
                guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 512,
                      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
                return text
            }
            let name = bounded(spanish ? row.product_name_es : row.product_name_en) ?? bounded(row.product_name)
            let quantity = bounded(row.quantity)
            guard name != nil || quantity != nil else { return nil }
            let modified = row.last_modified_t.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil }
            return .init(barcode: code, name: name, quantity: quantity, fetched: instant, modified: modified)
        }
        let id = UUID()
        pending[key] = Pending(id: id, task: task)
        defer { if pending[key]?.id == id { pending.removeValue(forKey: key) } }
        do {
            let value = try await task.value
            guard !task.isCancelled, pending[key]?.id == id else { throw CancellationError() }
            if cache.count >= 96, let oldest = cache.min(by: { $0.value.time < $1.value.time })?.key { cache.removeValue(forKey: oldest) }
            cache[key] = .init(time: instant, value: value)
            return value
        } catch ProductBatchError.rateLimited {
            backoff = instant.addingTimeInterval(60)
            throw ProductBatchError.rateLimited
        }
    }

    private static func request(_ request: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: CatalogNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.expectedContentLength <= 32_768 else { throw ProductBatchError.lookupUnavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 32_768 else { throw ProductBatchError.lookupUnavailable }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}
