import Foundation

public enum ClientError: Error, Equatable, Sendable {
    case configuration, invalidResponse, sessionNeeded, accessEnded, cancelled
    case service(status: Int, code: String, correlationID: String?, retryAfter: TimeInterval?)
    case transport
}

/// Authentication and API endpoints are separately configured. No production hosts or credentials are inferred.
public struct ServiceConfiguration: Sendable {
    public let baseURL: URL
    public init(baseURL: URL) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw ClientError.configuration }
        self.baseURL = baseURL
    }
}

public struct HTTPTransport: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        }
    }
    public func send(_ request: URLRequest) async throws -> Data {
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw ClientError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw ClientError.cancelled }
        catch { throw ClientError.transport }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ClientError.sessionNeeded }
            if http.statusCode == 403 { throw ClientError.accessEnded }
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let retry: TimeInterval?
            if let value = http.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Double(value) { retry = max(0, seconds) }
                else { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    retry = formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
                }
            } else { retry = nil }
            throw ClientError.service(status: http.statusCode, code: envelope?.error.code ?? "service_unavailable",
                correlationID: envelope?.error.correlationId, retryAfter: retry)
        }
        guard data.count <= 2_000_000 else { throw ClientError.invalidResponse }
        return data
    }
    func json<Response: Decodable & Sendable>(_ request: URLRequest, as: Response.Type = Response.self) async throws -> Response {
        let data = try await send(request)
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }
}
private struct ErrorEnvelope: Decodable { struct Detail: Decodable { let code: String; let correlationId: String? }; let error: Detail }
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
func request(base: URL, path: String, method: String, token: String? = nil, body: Data? = nil) -> URLRequest {
    var result = URLRequest(url: base.appendingPathComponent(path))
    result.httpMethod = method; result.httpBody = body
    result.setValue("application/json", forHTTPHeaderField: "Accept")
    result.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    if body != nil { result.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { result.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return result
}
