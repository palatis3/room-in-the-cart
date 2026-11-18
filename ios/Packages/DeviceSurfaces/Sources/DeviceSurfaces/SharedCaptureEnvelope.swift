import Foundation
import UniformTypeIdentifiers

/// A handoff contains source material only. The app chooses the destination and
/// obtains its authorization when the person opens the review.
public struct SharedCaptureEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case recipeURL, receiptFile }
    public let version: Int
    public let kind: Kind
    public let value: String

    public init(recipeURL url: URL) throws {
        guard url.absoluteString.utf8.count <= 4096,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443
        else { throw SurfaceError.invalid }
        version = 1
        kind = .recipeURL
        value = url.absoluteString
    }

    init(receipt: SharedReceiptDescriptor) throws {
        version = 1
        kind = .receiptFile
        value = String(decoding: try canonical(receipt), as: UTF8.self)
    }

    public static func loadRecipeURL(from provider: NSItemProvider,
                                     completion: @escaping @Sendable (Result<Self, SurfaceError>) -> Void) {
        provider.loadObject(ofClass: NSURL.self) { object, error in
            guard error == nil, let url = object as? URL else { completion(.failure(.unsupported)); return }
            do { completion(.success(try Self(recipeURL: url))) }
            catch { completion(.failure(.invalid)) }
        }
    }
}

public struct SharedCaptureEntry: Sendable, Equatable, Identifiable {
    public var id: UUID { receipt.operationID }
    public let receipt: InboxReceipt
    public let envelope: SharedCaptureEnvelope
}

/// Reuse the selected-text store's protected transactions, replay receipts,
/// capacity and expiration. A separate file keeps typed envelopes out of Shop.
public struct SharedCaptureInbox: Sendable {
    let storage: SelectedTextInbox
    public init(url: URL) throws {
        storage = try SelectedTextInbox(url: url, kind: "shared-capture-inbox")
    }
    public func stage(_ envelope: SharedCaptureEnvelope, id: UUID, now: Date) async throws -> InboxReceipt {
        guard envelope.kind == .recipeURL else { throw SurfaceError.invalid }
        try validate(envelope)
        let text = String(decoding: try canonical(envelope), as: UTF8.self)
        return try await storage.stage(operationID: id, originalText: text, now: now)
    }
    public func pendingRecipes(now: Date) async throws -> [SharedCaptureEntry] {
        try await storage.pending(now: now).compactMap { row in
            struct Header: Decodable { let version: Int; let kind: String }
            let bytes = Data(row.originalText.utf8)
            let header = try JSONDecoder().decode(Header.self, from: bytes)
            // Newer clients may share another supported kind using the same inbox.
            guard header.version == 1, header.kind == SharedCaptureEnvelope.Kind.recipeURL.rawValue else { return nil }
            let envelope = try JSONDecoder().decode(SharedCaptureEnvelope.self, from: bytes)
            try validate(envelope)
            return SharedCaptureEntry(receipt: row.receipt, envelope: envelope)
        }
    }
    public func discard(_ entry: SharedCaptureEntry, now: Date) async throws {
        guard entry.envelope.kind == .recipeURL else { throw SurfaceError.invalid }
        _ = try await storage.discard(operationID: entry.id, digest: entry.receipt.digest, now: now)
    }
    private func validate(_ envelope: SharedCaptureEnvelope) throws {
        guard envelope.version == 1, let url = URL(string: envelope.value),
              try SharedCaptureEnvelope(recipeURL: url) == envelope else { throw SurfaceError.invalid }
    }
}
