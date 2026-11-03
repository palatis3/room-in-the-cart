import Foundation

/// A token provider supplied by the authenticated session. Credentials and JWS are never logged.
/// This adapter accepts only TLS origins and does not cache entitlement responses on disk.
@MainActor final class HTTPMembershipEntitlementService: MembershipEntitlementService {
    private let baseURL: URL
    private let token: () async throws -> String
    private let deviceToken: () async throws -> String
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil, deviceToken: @escaping () async throws -> String,
         token: @escaping () async throws -> String) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw MembershipFailure.notConfigured }
        self.baseURL = baseURL
        self.token = token
        self.deviceToken = deviceToken
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: MembershipNoRedirects(), delegateQueue: nil)
        }
    }

    func purchaseContext(householdID: String) async throws -> UUID {
        struct Response: Decodable { let appAccountToken: UUID }
        let response: Response = try await request(path: "v1/households/\(try identifier(householdID))/billing/purchase-context", method: "POST", body: Data("{}".utf8))
        return response.appAccountToken
    }

    func submit(_ transaction: SignedMembershipTransaction, context: MembershipContext) async throws -> MembershipDeliveryReceipt {
        struct Body: Encodable { let householdId: String; let signedTransactionInfo: String }
        return try await request(path: "v1/billing/verify", method: "POST", body: JSONEncoder().encode(
            Body(householdId: context.householdID, signedTransactionInfo: transaction.signedTransactionInfo)))
    }

    func fetch(context: MembershipContext) async throws -> MembershipSnapshot {
        try await request(path: "v1/households/\(try identifier(context.householdID))/entitlements", method: "GET")
    }

    func seatCandidates(context: MembershipContext) async throws -> [MembershipSeat] {
        struct Response: Decodable { let adults: [MembershipSeat] }
        let response: Response = try await request(path: "v1/households/\(try identifier(context.householdID))/billing/seat-candidates", method: "GET")
        return response.adults
    }

    func replaceSeat(userID: String?, replacingUserID: String?, context: MembershipContext, revision: Int) async throws -> MembershipSnapshot {
        let current = try await fetch(context: context)
        guard current.revision == revision else { throw MembershipFailure.refreshRequired }
        var ids = current.seats.map(\.userID).filter { $0 != replacingUserID }
        if let userID, !ids.contains(userID) { ids.append(userID) }
        struct Body: Encodable { let revision: Int; let userIDs: [String] }
        return try await request(path: "v1/households/\(try identifier(context.householdID))/billing/seats", method: "PUT",
            body: JSONEncoder().encode(Body(revision: revision, userIDs: ids)))
    }

    private func identifier(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw MembershipFailure.wrongHousehold }
        return value
    }

    private func request<Response: Decodable>(path: String, method: String, body: Data? = nil) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let access = try await token()
        let device = try await deviceToken()
        guard !access.isEmpty, !device.isEmpty else { throw MembershipFailure.signInRequired }
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(device, forHTTPHeaderField: "X-Device-Token")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MembershipFailure.deliveryPending }
        guard data.count <= 1_000_000 else { throw MembershipFailure.invalidSnapshot }
        guard (200...299).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(MembershipErrorEnvelope.self, from: data))?.error.code
            switch code {
            case "purchase_already_bound": throw MembershipFailure.wrongHousehold
            case "purchase_context_not_purchaser": throw MembershipFailure.notPurchaser
            case "session_needed", "access_ended": throw MembershipFailure.signInRequired
            case "refresh_required": throw MembershipFailure.refreshRequired
            case "membership_inactive": throw MembershipFailure.membershipInactive
            case "billing_verification_failed": throw MembershipFailure.unverified
            case "billing_unavailable", "storage_unavailable", "rate_limited": throw MembershipFailure.deliveryPending
            default:
                if response.statusCode == 401 || response.statusCode == 403 { throw MembershipFailure.signInRequired }
                if response.statusCode == 429 || response.statusCode >= 500 { throw MembershipFailure.deliveryPending }
                throw MembershipFailure.serverRejected
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw MembershipFailure.invalidSnapshot }
            return date
        }
        return try decoder.decode(Response.self, from: data)
    }
}

private struct MembershipErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
}

private final class MembershipNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
