import Foundation

public struct RetryPolicy: Sendable {
    public let maximumAttempts: Int
    public init(maximumAttempts: Int = 5) { self.maximumAttempts = max(1, maximumAttempts) }
    /// No loop runs implicitly. The caller may offer a manual retry after this deadline using the same stored bytes.
    public func delay(attempt: Int, error: ClientError, jitter: Double = Double.random(in: 0...1)) -> TimeInterval? {
        guard attempt < maximumAttempts else { return nil }
        let serverDelay: TimeInterval?
        switch error {
        case .transport: serverDelay = nil
        case .service(let status, _, _, let retryAfter) where status == 429 || status >= 500: serverDelay = retryAfter
        default: return nil
        }
        let backoff = min(60, pow(2, Double(max(0, attempt)))) + max(0, min(1, jitter))
        return max(backoff, serverDelay ?? 0)
    }
}

/// Safe helper projection has no price, household roster, other requests, or private planning fields.
/// Service capability is currently unavailable: this type does not imply an active share grant.
public struct ScopedCookView: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let item: String; public let amount: String?; public let action: String?; public let basis: String?
    }
    public let grantId: String; public let shopId: String; public let revision: Int
    public let generatedAt: String; public let expiresAt: String; public let items: [Item]
}
