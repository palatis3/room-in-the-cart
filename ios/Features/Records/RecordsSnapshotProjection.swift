import Foundation
import LocalStore
import RecordArchive
import HouseholdClient

struct RecordsUnavailableRecord: Equatable, Identifiable {
    enum Reason: Equatable { case unreadableStorage, unsupportedStorage, invalidNative }
    let origin: String
    let recordID: String
    let title: String?
    let reason: Reason
    let localCopyID: String?
    var id: [String?] { [origin, recordID, localCopyID] }
    init(origin: String, recordID: String, title: String?, reason: Reason, localCopyID: String? = nil) {
        self.origin = origin; self.recordID = recordID; self.title = title; self.reason = reason; self.localCopyID = localCopyID
    }
}
struct RecordsSnapshotBatch {
    var records: [ArchiveRecord] = []
    var unavailable: [RecordsUnavailableRecord] = []
}

@MainActor enum RecordsSnapshotProjection {
    static func liveSharedRecords(householdID: String, shopID: UUID, authorized: () -> Bool,
                                  current: @escaping () async throws -> ArchiveRecord,
                                  history: @escaping () async throws -> ArchiveRecord) async throws -> RecordsSnapshotBatch {
        let shop = shopID.uuidString.lowercased()
        let currentWarning = RecordsUnavailableRecord(origin: "shared-shop/" + householdID, recordID: shop,
                                                     title: nil, reason: .unreadableStorage)
        let historyWarning = RecordsUnavailableRecord(origin: "shared-history/" + householdID, recordID: shop + "/history",
                                                     title: recordsText("Shared pickup history"), reason: .unreadableStorage)
        var batch = RecordsSnapshotBatch()
        for (warning, read) in [(currentWarning, current), (historyWarning, history)] {
            guard authorized() else { throw ArchiveError.unavailable }
            do {
                let record = try await read()
                batch.records.append(record)
            } catch {
                guard authorized() else { throw ArchiveError.unavailable }
                if let failure = error as? ClientError {
                    switch failure {
                    case .accessEnded, .sessionNeeded, .cancelled,
                         .service(status: 404, code: "unavailable", correlationID: _, retryAfter: _):
                        // An authoritative denial applies to both live reads of the same shop.
                        return RecordsSnapshotBatch(records: [], unavailable: [currentWarning, historyWarning])
                    default: break
                    }
                }
                if error is CancellationError { throw error }
                batch.unavailable.append(warning)
            }
        }
        guard authorized() else { throw ArchiveError.unavailable }
        return batch
    }

    static func mergeForExport(_ records: [ArchiveRecord]) throws -> [ArchiveRecord] {
        var merged: [ArchiveRecord] = []
        var indices: [RecordsSelectionID: Int] = [:]
        for record in records {
            let key = RecordsToolsModel.selectionID(record)
            guard let index = indices[key] else {
                indices[key] = merged.count
                merged.append(record)
                continue
            }
            var attachments = merged[index].media ?? []
            for attachment in record.media ?? [] {
                if let existing = attachments.first(where: { $0.id == attachment.id }) {
                    guard existing == attachment else { throw ArchiveError.conflict }
                } else { attachments.append(attachment) }
            }
            // A redacted copy omits the native payload. Retain the complete owner
            // record even when the helper was imported more recently.
            if merged[index].nativePayload == nil, record.nativePayload != nil {
                merged[index] = record
            }
            merged[index].media = attachments.isEmpty ? nil : attachments.sorted { $0.id < $1.id }
        }
        return merged
    }

    /// Storage listing errors are thrown before this projection. Only individual
    /// payload failures are isolated here; their original bytes remain untouched.
    static func project(_ listing: ComparisonListing, origin: String, localCopyID: String? = nil,
                        decode: (SavedComparison) throws -> ArchiveRecord) -> RecordsSnapshotBatch {
        var result = RecordsSnapshotBatch()
        result.unavailable = listing.unavailable.map { row in
            let reason: RecordsUnavailableRecord.Reason
            if case .unsupportedEnvelope = row.reason { reason = .unsupportedStorage }
            else { reason = .unreadableStorage }
            return RecordsUnavailableRecord(origin: origin, recordID: row.id.uuidString, title: row.title, reason: reason, localCopyID: localCopyID)
        }
        for row in listing.records {
            do { result.records.append(try decode(row)) }
            catch { result.unavailable.append(RecordsUnavailableRecord(origin: origin, recordID: row.id.uuidString, title: row.title, reason: .invalidNative, localCopyID: localCopyID)) }
        }
        return result
    }
}
