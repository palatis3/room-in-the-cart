import Foundation
import CryptoKit
import RecordArchive

/// Transport encryption for a complete multipart recovery document. A decrypted
/// part alone is never a restorable snapshot: PantryArchiveStorage must verify the
/// inner manifest, exact file set and complete graph before publishing a copy.
enum PantryRecoveryEncryption {
    enum Failure: Error, Equatable { case tooLarge, invalidName, invalidEnvelope, unsupportedVersion, invalidKey, locked }
    struct Context: Codable, Equatable {
        let bundleID: UUID
        let name: String
    }
    private struct Container: Codable {
        let namespace: String
        let version: Int
        let algorithm: String
        let context: Context
        let combined: Data
    }
    static let maximumPlaintextBytes = ArchiveCodec.maximumNativeBytes
    static let maximumEncryptedBytes = 6 * 1_048_576
    private static let namespace = "room-in-the-cart/pantry-recovery-part"

    static func seal(_ bytes: Data, context: Context, key: String) throws -> Data {
        try validate(context)
        guard !bytes.isEmpty, bytes.count <= maximumPlaintextBytes else { throw Failure.tooLarge }
        let sealed = try AES.GCM.seal(bytes, using: symmetricKey(key), authenticating: associatedData(context))
        guard let combined = sealed.combined else { throw Failure.locked }
        let data = try ArchiveCodec.canonical(Container(namespace: namespace, version: 1,
            algorithm: "AES-256-GCM", context: context, combined: combined))
        guard data.count <= maximumEncryptedBytes else { throw Failure.tooLarge }
        return data
    }

    /// Unauthenticated routing metadata only; no pantry contents or permissions.
    static func context(in bytes: Data) throws -> Context { try container(bytes).context }

    static func open(_ bytes: Data, context expected: Context, key: String) throws -> Data {
        try validate(expected)
        let container = try container(bytes)
        guard container.context == expected else { throw Failure.locked }
        let key = try symmetricKey(key)
        do {
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: container.combined), using: key,
                authenticating: associatedData(expected))
            guard !plaintext.isEmpty, plaintext.count <= maximumPlaintextBytes else { throw Failure.tooLarge }
            return plaintext
        } catch let failure as Failure { throw failure }
        catch { throw Failure.locked }
    }

    private static func container(_ bytes: Data) throws -> Container {
        guard !bytes.isEmpty, bytes.count <= maximumEncryptedBytes else { throw Failure.tooLarge }
        do {
            try ArchiveCodec.preflight(bytes, maximum: maximumEncryptedBytes)
            let value = try JSONDecoder().decode(Container.self, from: bytes)
            guard value.namespace == namespace, value.version == 1, value.algorithm == "AES-256-GCM" else {
                throw Failure.unsupportedVersion
            }
            try validate(value.context)
            guard (28...(maximumPlaintextBytes + 28)).contains(value.combined.count),
                  try ArchiveCodec.canonical(value) == bytes else { throw Failure.invalidEnvelope }
            return value
        } catch let failure as Failure { throw failure }
        catch { throw Failure.invalidEnvelope }
    }

    private static func associatedData(_ context: Context) throws -> Data {
        Data("\(namespace)/v1/AES-256-GCM/".utf8) + (try ArchiveCodec.canonical(context))
    }
    private static func symmetricKey(_ value: String) throws -> SymmetricKey {
        guard let bytes = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 32 else {
            throw Failure.invalidKey
        }
        return SymmetricKey(data: bytes)
    }
    private static func validate(_ context: Context) throws {
        if context.name == "manifest.json" { return }
        for prefix in ["pantry-", "scope-"] where context.name.hasPrefix(prefix) && context.name.hasSuffix(".json") {
            let suffix = context.name.dropFirst(prefix.count).dropLast(5)
            if let index = Int(suffix), index >= 0, context.name == "\(prefix)\(index).json" { return }
        }
        throw Failure.invalidName
    }
}
