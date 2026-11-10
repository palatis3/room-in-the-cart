import Foundation
import CoreDomain
import RecordArchive

/// Only the existing typed, reduced source-evidence record crosses this boundary.
/// Dates, original wording and literal receipt notes remain evidence, never facts
/// applied to quantities, payments, grants or meal approval.
@MainActor enum RecordsMediaCodec {
    private struct Evidence: Codable {
        let formatMajor: Int
        let source: SourceMediaRecord
    }
    static func attachment(_ source: SourceMediaRecord) throws -> ArchiveMediaAttachment {
        try source.validate()
        return ArchiveMediaAttachment(id: source.id.uuidString, kind: kind(source.target.kind),
            data: try ArchiveCodec.canonical(Evidence(formatMajor: 1, source: source)))
    }
    static func decode(_ attachment: ArchiveMediaAttachment) throws -> SourceMediaRecord {
        try ArchiveCodec.preflight(attachment.data, maximum: ArchiveCodec.maximumMediaBytes)
        let value: Evidence
        do { value = try JSONDecoder().decode(Evidence.self, from: attachment.data) }
        catch { throw ArchiveError.malformed }
        guard value.formatMajor == 1 else { throw ArchiveError.unsupportedVersion }
        do { try value.source.validate() } catch { throw ArchiveError.integrity }
        guard attachment.id == value.source.id.uuidString,
              attachment.kind == kind(value.source.target.kind) else { throw ArchiveError.invalidIdentity }
        // Unknown keys, including credentials nested in evidence, cannot survive.
        guard try ArchiveCodec.canonical(value) == attachment.data else { throw ArchiveError.unsupportedRecord }
        return value.source
    }
    static func validate(_ record: ArchiveRecord) throws {
        guard let media = record.media else { return }
        guard media.count <= ArchiveCodec.maximumMediaAttachments, record.nativePayload != nil else { throw ArchiveError.unsupportedRecord }
        for attachment in media {
            let source = try decode(attachment)
            guard try belongs(source, to: record, captureNamespace: attachment.captureNamespace) else { throw ArchiveError.invalidIdentity }
        }
    }
    static func attaching(_ sources: [SourceMediaRecord], to original: ArchiveRecord, liveScope: RecordsRecoveryCapture.Scope? = nil) throws -> ArchiveRecord {
        var record = original, attachments = record.media ?? []
        for source in sources {
            let media = try liveScope?.attachment(source) ?? attachment(source)
            guard try belongs(source, to: record, captureNamespace: media.captureNamespace) else { continue }
            if let existing = attachments.first(where: { $0.id == media.id }) {
                guard existing == media else { throw ArchiveError.conflict }
            } else { attachments.append(media) }
        }
        record.media = attachments.isEmpty ? nil : attachments.sorted { $0.id < $1.id }
        return record
    }
    static func belongs(_ source: SourceMediaRecord, to record: ArchiveRecord, captureNamespace: ArchiveCaptureNamespace? = nil) throws -> Bool {
        let target = source.target
        guard let bytes = record.nativePayload else { return false }
        if let captureNamespace {
            try captureNamespace.validate(origin: record.origin, recordKind: record.kind, mediaKind: kind(target.kind))
            guard captureNamespace.physicalWorkspaceID == target.workspaceID else { return false }
        }
        switch record.kind {
        case .ledger:
            guard captureNamespace != nil || record.origin == "ledger/" + target.workspaceID.uuidString else { return false }
            let workspace = try RecordsNativeCodec.ledger(bytes)
            if target.kind == .packageReference {
                return workspace.shops.contains { shop in
                    shop.id == target.containerID && shop.id.uuidString == record.id &&
                    shop.lines.contains { $0.id == target.objectID }
                }
            }
            guard target.kind == .recipeSource, target.containerID == target.workspaceID else { return false }
            func matches(_ id: UUID?, _ evidence: RecipeSourceEvidence?) -> Bool {
                id == target.objectID && evidence?.captureID == source.id &&
                evidence?.localMedia == RecipeLocalMediaReference(workspaceID: target.workspaceID, mediaID: source.id)
            }
            return workspace.mealTemplates.contains { matches($0.id, $0.sourceEvidence) } ||
                workspace.dinnerPlanning.acceptedDinners.contains { matches($0.template.id, $0.template.sourceEvidence) } ||
                workspace.shops.contains { shop in shop.mealOccurrences.contains { matches($0.templateID, $0.sourceEvidence) } }
        case .pickup:
            guard (captureNamespace != nil || record.origin == "pickups/" + target.workspaceID.uuidString),
                  target.kind == .receiptEvidence, record.id == target.containerID.uuidString,
                  target.objectID == target.containerID else { return false }
            return try RecordsNativeCodec.pickup(bytes).id == target.containerID
        case .comparison, .recipe, .sharedShop: return false
        }
    }
    private static func kind(_ value: CaptureTarget.Kind) -> ArchiveMediaKind {
        switch value { case .packageReference: return .packageReference; case .recipeSource: return .recipeSource; case .receiptEvidence: return .receiptEvidence }
    }
}
