import Foundation

/// Metadata for a completely verified external pantry package. The registry does
/// not embed its graph or derive filesystem paths from imported content.
public struct PantryRecoveryReference: Codable, Equatable, Sendable {
    public let bundleID: UUID
    public let manifestDigest: Data
    public let originID: UUID
    public let inventoryRevision: Int64
    public init(bundleID: UUID, manifestDigest: Data, originID: UUID, inventoryRevision: Int64) {
        self.bundleID = bundleID; self.manifestDigest = manifestDigest
        self.originID = originID; self.inventoryRevision = inventoryRevision
    }
    func validate() throws {
        guard manifestDigest.count == 32, inventoryRevision >= 0 else { throw ArchiveError.integrity }
    }
}

public struct RecoveredPantryCopy: Codable, Equatable, Sendable, Identifiable {
    public enum Materialization: Codable, Equatable, Sendable {
        case unmaterialized
        case started(attemptID: UUID)
        case ready(workspaceID: UUID)
    }
    public let id: UUID
    public let reference: PantryRecoveryReference
    public let recoveredAtMilliseconds: Int64
    public let lifetime: UUID
    public internal(set) var materialization: Materialization
}

public struct PantryRecoveryReview: Sendable {
    public let reference: PantryRecoveryReference
    public let disposition: RecoveryDisposition
    public let existingCopy: RecoveredPantryCopy?
    let generation: UUID
    public var canApply: Bool { disposition != .quarantined && disposition != .erased }
}

public struct PantryMaterializationStart: Sendable {
    public let copy: RecoveredPantryCopy
    /// Only the call that commits the first attempt may create storage. A retry
    /// opens the already bound directory or reports interrupted/missing storage.
    public let permitsCreation: Bool
}

public struct PantryDeletionReview: Sendable {
    public let copies: [RecoveredPantryCopy]
    let generation: UUID
}
