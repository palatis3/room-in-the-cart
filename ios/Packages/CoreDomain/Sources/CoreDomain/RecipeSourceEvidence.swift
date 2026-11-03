import Foundation

public enum RecipeSourceKind: String, Codable, CaseIterable, Sendable {
    case typed, pasted, photoOCR
}

public enum RecipeSourceError: Error, Equatable, Sendable {
    case invalidOriginalText
    case invalidIdentifier
    case unknownFields
}

/// Supplied by the live caller, never decoded from a recipe or archive. A namespace
/// in imported evidence is data, not permission to inspect a local media object.
public enum RecipeMediaLookupScope: Equatable, Sendable {
    case activeNativeWorkspace(UUID)
    case importedOrRecovered
}

/// An opaque, namespace-bound reference only. No path, URL, bytes, or credentials.
public struct RecipeLocalMediaReference: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let mediaID: UUID

    public init(workspaceID: UUID, mediaID: UUID) {
        self.workspaceID = workspaceID; self.mediaID = mediaID
    }

    /// An eligible candidate ID, not a claim that bytes exist or access is authorized.
    /// The media store must still check the live scope, target binding, and actual bytes.
    public func localMediaID(in scope: RecipeMediaLookupScope) -> UUID? {
        guard case let .activeNativeWorkspace(activeID) = scope, activeID == workspaceID else { return nil }
        return mediaID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case workspaceID, mediaID }
    public init(from decoder: Decoder) throws {
        try recipeEvidenceKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try recipeEvidenceUUID(c, key: .workspaceID)
        mediaID = try recipeEvidenceUUID(c, key: .mediaID)
    }
}

/// Original source wording remains independent of the reviewed title, ingredients,
/// servings, notes, and attribution URL. Creating evidence never chooses a meal or
/// interprets a quantity, source link, guest count, or permission from its text.
public struct RecipeSourceEvidence: Codable, Equatable, Sendable {
    public static let maximumOriginalTextBytes = 20_000
    public let captureID: UUID
    public let originalText: String
    public let kind: RecipeSourceKind
    public let localMedia: RecipeLocalMediaReference?

    public init(captureID: UUID, originalText: String, kind: RecipeSourceKind,
                localMedia: RecipeLocalMediaReference? = nil) throws {
        self.captureID = captureID; self.originalText = originalText; self.kind = kind; self.localMedia = localMedia
        try validate()
    }

    public func validate() throws {
        guard originalText.utf8.count <= Self.maximumOriginalTextBytes,
              !originalText.contains("\0"),
              !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RecipeSourceError.invalidOriginalText }
    }

    /// Nil includes text-only capture, foreign namespaces, and all recovered/imported
    /// contexts. Keep the recipe usable and show unavailable media honestly in those cases.
    public func localMediaID(in scope: RecipeMediaLookupScope) -> UUID? {
        localMedia?.localMediaID(in: scope)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case captureID, originalText, kind, localMedia }
    public init(from decoder: Decoder) throws {
        try recipeEvidenceKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(captureID: recipeEvidenceUUID(c, key: .captureID),
            originalText: c.decode(String.self, forKey: .originalText),
            kind: c.decode(RecipeSourceKind.self, forKey: .kind),
            localMedia: c.decodeIfPresent(RecipeLocalMediaReference.self, forKey: .localMedia))
    }
}

private struct RecipeEvidenceKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func recipeEvidenceKeys(_ decoder: Decoder, allowed: [String]) throws {
    let c = try decoder.container(keyedBy: RecipeEvidenceKey.self)
    guard Set(c.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else { throw RecipeSourceError.unknownFields }
}

private func recipeEvidenceUUID<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, key: Key) throws -> UUID {
    let text = try c.decode(String.self, forKey: key)
    guard text.utf8.count == 36, let id = UUID(uuidString: text) else { throw RecipeSourceError.invalidIdentifier }
    return id
}
