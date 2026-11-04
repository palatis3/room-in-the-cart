import Foundation
import SwiftUI
import RecordArchive

/// Native export/validation/open/delete are provided by the composition root. Validation
/// must decode and re-encode an allowlisted domain payload, never raw database/account data.
@MainActor final class RecordsToolsModel: ObservableObject {
    typealias Snapshot = () async throws -> [ArchiveRecord]
    typealias Validate = (ArchiveRecord) async throws -> Void
    typealias Open = (RecoveredRecord) async throws -> Void
    typealias Delete = (ArchiveRecord) async throws -> Void
    typealias Authorization = @MainActor @Sendable () -> Bool

    @Published private(set) var currentRecords: [ArchiveRecord] = []
    @Published private(set) var recoveredRecords: [RecoveredRecord] = []
    @Published private(set) var unavailableRecords: [RecordsUnavailableRecord] = []
    @Published private(set) var review: RecoveryReview?
    @Published private(set) var recipeReport: RecipeImportReport?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    /// A completed model action supplies a new focus target; view state cannot
    /// announce success before the underlying operation has finished.
    @Published private(set) var actionOutcomeID: UUID?
    @Published private(set) var error: ArchiveError?
    @Published var selectedIDs: Set<String> = []
    /// Attachment disclosure is separate from record selection and defaults off.
    @Published var selectedMediaIDs: Set<String> = []
    @Published var recoveryKey = ""
    @Published private(set) var preparedDocument: RecordsFileDocument?
    @Published private(set) var preparedName = "Room-in-the-Cart"
    @Published private(set) var preparedIsPrivate = false
    @Published private(set) var lastImportIDs: [String] = []
    @Published private(set) var deleteUndo: RecoveryUndoToken?
    let registry: RecoveryRegistry
    private let snapshot: Snapshot
    private let unavailableSnapshot: () -> [RecordsUnavailableRecord]
    private let validate: Validate
    private let open: Open
    private let deleteSource: Delete?
    private let wholeLedgerDeletionAction: (() async throws -> Void)?
    private let cleanupRecovered: (() async throws -> Void)?
    private let willRemoveRecovered: () -> Void
    private var recoveredOpenGeneration = UUID()
    private let deletable: (ArchiveRecord) -> Bool
    private let sourceUndo: (() async throws -> Void)?
    private let beginAuthorization: () -> Authorization?
    @Published private(set) var canUndoSourceDeletion = false
    private var selectedSnapshot: [ArchiveRecord] { currentRecords.filter { selectedIDs.contains(Self.selectionID($0)) } }
    var selectedCount: Int { selectedSnapshot.count }
    var selectedMediaCount: Int { selectedSnapshot.reduce(0) { count, record in count + (record.media ?? []).filter { selectedMediaIDs.contains(Self.mediaSelectionID($0, record: record)) }.count } }
    var selectedMediaBytes: Int { selectedSnapshot.reduce(0) { count, record in count + (record.media ?? []).filter { selectedMediaIDs.contains(Self.mediaSelectionID($0, record: record)) }.reduce(0) { $0 + $1.data.count } } }
    func canDeleteSource(_ record: ArchiveRecord) -> Bool { deleteSource != nil && deletable(record) }
    var canReviewWholeLedgerDeletion: Bool { wholeLedgerDeletionAction != nil }
    var recoveredDeletionAllowsUndo: Bool { cleanupRecovered == nil }
    var supportText: String { ReadableArchive.supportReport(error: error, recordCount: currentRecords.count + recoveredRecords.count) }
    static func selectionID(_ record: ArchiveRecord) -> String { record.origin + "/" + record.id + "/" + record.revision }
    static func mediaSelectionID(_ media: ArchiveMediaAttachment, record: ArchiveRecord) -> String { selectionID(record) + "/media/" + media.id }

    init(registry: RecoveryRegistry, snapshot: @escaping Snapshot, validateNativePayload: @escaping Validate,
         openRecovered: @escaping Open, deleteSource: Delete? = nil, undoSourceDeletion: (() async throws -> Void)? = nil, canDeleteSource: @escaping (ArchiveRecord) -> Bool = { _ in true }, cleanupRecoveredWorkspaces: (() async throws -> Void)? = nil, willRemoveRecovered: @escaping () -> Void = {}, reviewWholeLedgerDeletion: (() async throws -> Void)? = nil, unavailableRecords: @escaping () -> [RecordsUnavailableRecord] = { [] }, beginAuthorization: @escaping () -> Authorization? = { { true } }) {
        self.registry = registry; self.snapshot = snapshot; self.validate = validateNativePayload
        self.open = openRecovered; self.deleteSource = deleteSource; self.sourceUndo = undoSourceDeletion; self.deletable = canDeleteSource; self.cleanupRecovered = cleanupRecoveredWorkspaces; self.wholeLedgerDeletionAction = reviewWholeLedgerDeletion
        self.unavailableSnapshot = unavailableRecords
        self.beginAuthorization = beginAuthorization
        self.willRemoveRecovered = willRemoveRecovered
    }
    private func readSnapshot() async throws -> [ArchiveRecord] {
        let records = try await snapshot()
        unavailableRecords = unavailableSnapshot()
        return records
    }
    func refresh() async {
        do {
            let authorize = try authorization()
            currentRecords = try await readSnapshot()
            try requireAuthorization(authorize)
            recoveredRecords = try await registry.refreshList()
            try requireAuthorization(authorize)
            selectedIDs.formIntersection(Set(currentRecords.map(Self.selectionID)))
            selectedMediaIDs.formIntersection(Set(currentRecords.flatMap { record in (record.media ?? []).map { Self.mediaSelectionID($0, record: record) } }))
        } catch { fail(error) }
    }
    func selectAll() { selectedIDs = Set(currentRecords.map(Self.selectionID)) }
    func generateRecoveryKey() { recoveryKey = EncryptedArchive.generateKey() }
    enum ExportChoice { case encryptedRecovery, helperJSON, helperText, ownerText }
    func prepareExport(_ choice: ExportChoice) async {
        guard !busy else { return }
        busy = true; error = nil; preparedDocument = nil
        defer { busy = false }
        do {
            let authorize = try authorization()
            currentRecords = try await readSnapshot()
            try requireAuthorization(authorize)
            let records = selectedSnapshot.map { source -> ArchiveRecord in
                var record = source
                record.media = choice == .encryptedRecovery ? source.media?.filter { selectedMediaIDs.contains(Self.mediaSelectionID($0, record: source)) } : nil
                if record.media?.isEmpty == true { record.media = nil }
                return record
            }
            guard !records.isEmpty else { throw ArchiveError.unavailable }
            if choice == .helperJSON || choice == .helperText { guard records.count == 1 else { throw ArchiveError.unsupportedProjection } }
            for record in records { try await validateRecord(record); try requireAuthorization(authorize) }
            switch choice {
            case .encryptedRecovery, .helperJSON:
                let kind: ArchiveKind = choice == .encryptedRecovery ? .personalRecovery : .helperShop
                // Export identity depends on source revisions, not file creation time.
                let revision = ArchiveCodec.digest(try ArchiveCodec.canonical(records.map { [$0.origin, $0.id, $0.revision] }.sorted { $0.lexicographicallyPrecedes($1) }))
                let envelope = try ArchiveCodec.make(records: records, kind: kind, origin: "selected-local-records", revision: revision, shopID: kind == .helperShop ? records.first?.id : nil)
                let data = choice == .encryptedRecovery ? try EncryptedArchive.seal(envelope, key: recoveryKey) : try ArchiveCodec.encode(envelope)
                preparedDocument = RecordsFileDocument(data: data, kind: choice == .encryptedRecovery ? .recovery : .helper)
                preparedName = choice == .encryptedRecovery ? "Personal-recovery" : "Helper-copy"
                preparedIsPrivate = choice == .encryptedRecovery
            case .helperText, .ownerText:
                let bounded = try ArchiveCodec.make(records: records, kind: choice == .ownerText ? .personalRecovery : .helperShop,
                    origin: "selected-local-records", revision: "readable-preview")
                _ = try ArchiveCodec.encode(bounded)
                preparedDocument = RecordsFileDocument(data: Data(ReadableArchive.text(records, owner: choice == .ownerText).utf8), kind: .text)
                preparedName = choice == .ownerText ? "Private-readable-records" : "Cook-copy"
                preparedIsPrivate = choice == .ownerText
            }
            try requireAuthorization(authorize)
            status = recordsText("Your file is ready to review and save.")
        } catch { fail(error) }
    }
    func importFile(_ url: URL, recipes: Bool) async {
        guard !busy else { return }
        busy = true; review = nil; reviewAuthorization = nil; recipeReport = nil; error = nil
        defer { busy = false }
        do {
            let authorize = try authorization()
            let data = try await RecordsFileDocument.readPickedBytes(at: url)
            try Task.checkCancellation()
            try requireAuthorization(authorize)
            try ArchiveCodec.preflight(data)
            if recipes {
                let existing = try await registry.refreshList().compactMap { record -> ImportedRecipe? in
                    guard record.record.kind == .recipe, let bytes = record.record.nativePayload else { return nil }
                    return try? JSONDecoder().decode(ImportedRecipe.self, from: bytes)
                }
                try requireAuthorization(authorize)
                let report = try RecipeImporter.stage(data, existing: existing)
                let records = try report.recipes.map { try $0.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0)) }
                if records.isEmpty {
                    recipeReport = report
                    let message = recordsText(report.skippedRows == 0 ? "These recipes are already saved." : "No new recipes were saved.")
                    publishOutcome([message, report.localizedSummary, report.localizedUnsupportedFields].compactMap { $0 }.joined(separator: "\n"))
                    return
                }
                let envelope = try ArchiveCodec.make(records: records, kind: .personalRecovery, origin: "recipe-library-v1", revision: ArchiveCodec.digest(try ArchiveCodec.canonical(report.recipes)))
                try await stage(envelope, authorize: authorize)
                try requireAuthorization(authorize)
                recipeReport = report
            } else {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let envelope = object?["algorithm"] != nil ? try EncryptedArchive.open(data, key: recoveryKey) : try ArchiveCodec.decode(data)
                try await stage(envelope, authorize: authorize)
            }
        } catch { fail(error) }
    }
    func stageManualRecipe(_ recipe: ImportedRecipe) async {
        guard !busy else { return }
        busy = true; error = nil; review = nil; recipeReport = nil
        defer { busy = false }
        do {
            let authorize = try authorization()
            let record = try recipe.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0))
            try await stage(ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "recipe-library-v1", revision: recipe.id), authorize: authorize)
        } catch { fail(error) }
    }
    private var reviewAuthorization: Authorization?
    private func stage(_ envelope: ArchiveEnvelope, authorize: @escaping Authorization) async throws {
        for record in envelope.payload.records { try await validateRecord(record); try requireAuthorization(authorize) }
        let staged = try await registry.review(envelope)
        try requireAuthorization(authorize)
        reviewAuthorization = authorize
        review = staged
        status = nil
    }
    private func validateRecord(_ record: ArchiveRecord) async throws {
        try RecordsMediaCodec.validate(record)
        if record.kind == .recipe, let data = record.nativePayload {
            do {
                let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: data)
                _ = try recipe.validated()
                guard try ArchiveCodec.canonical(recipe) == data else { throw ArchiveError.unsupportedRecord }
            } catch { throw ArchiveError.invalidRecipe }
        }
        // Every projection must reconcile erasure, including helper-only records.
        try await validate(record)
    }
    func cancelReview() { review = nil; reviewAuthorization = nil; recipeReport = nil; publishOutcome(recordsText("Import cancelled. Your records are unchanged.")) }
    func applyReviewedImport() async {
        guard !busy, let review else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let authorize = try authorization()
            guard reviewAuthorization?() == true else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
            for record in review.envelope.payload.records {
                try await validateRecord(record); try requireAuthorization(authorize)
                guard reviewAuthorization?() == true else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
            }
            let result = try await registry.apply(review)
            guard authorize(), reviewAuthorization?() == true else {
                if !result.insertedCopyIDs.isEmpty { try await registry.undoImport(insertedCopyIDs: result.insertedCopyIDs) }
                invalidateForSourceErasure(); throw ArchiveError.unavailable
            }
            lastImportIDs = result.insertedCopyIDs
            self.review = nil; reviewAuthorization = nil; recipeReport = nil
            currentRecords = try await readSnapshot()
            try requireAuthorization(authorize)
            recoveredRecords = try await registry.refreshList()
            try requireAuthorization(authorize)
            publishOutcome(result.insertedCount == 0 ? recordsText("Opened the existing recovered copies. Nothing was duplicated.") : recordsText("Saved separate recovered copies. Your current work is unchanged."))
        } catch { fail(error) }
    }
    func undoImport() async {
        guard !lastImportIDs.isEmpty else { return }
        do {
            let authorize = try authorization()
            cancelRecoveredOpen()
            try await registry.undoImport(insertedCopyIDs: lastImportIDs); lastImportIDs = []; try await cleanupRecovered?()
            try requireAuthorization(authorize)
            currentRecords = try await readSnapshot(); recoveredRecords = try await registry.refreshList()
            try requireAuthorization(authorize)
            publishOutcome(recordsText("The imported batch was undone."))
        }
        catch { fail(error) }
    }
    func openRecovered(_ record: RecoveredRecord) async {
        let generation = recoveredOpenGeneration
        do {
            let authorize = try authorization()
            try await validateRecord(record.record); try requireAuthorization(authorize)
            guard recoveredOpenGeneration == generation else { return }
            try await open(record); try requireAuthorization(authorize)
            guard recoveredOpenGeneration == generation else { return }
            if record.record.kind != .recipe { lastImportIDs = [] }
        } catch { if recoveredOpenGeneration == generation { fail(error) } }
    }
    private func cancelRecoveredOpen() { recoveredOpenGeneration = UUID(); willRemoveRecovered() }
    func deleteRecovered(_ scope: RecoveryDeleteScope) async {
        do {
            let authorize = try authorization()
            cancelRecoveredOpen()
            let token = try await registry.delete(scope)
            let outcome: String
            if let cleanupRecovered {
                deleteUndo = nil
                await registry.discardUndo()
                try await cleanupRecovered()
                outcome = recordsText("The recovered copies and their separate workspaces were permanently deleted from this iPhone.")
            } else {
                deleteUndo = token
                outcome = recordsText("Deleted from this iPhone. Undo is available until you leave the app.")
            }
            try requireAuthorization(authorize)
            currentRecords = try await readSnapshot()
            recoveredRecords = try await registry.refreshList()
            try requireAuthorization(authorize)
            publishOutcome(outcome)
        }
        catch { fail(error) }
    }
    func undoRecoveredDeletion() async {
        guard let token = deleteUndo else { return }
        do { try await registry.undoDelete(token); deleteUndo = nil; recoveredRecords = try await registry.refreshList(); publishOutcome(recordsText("Deletion undone.")) } catch { fail(error) }
    }
    func deleteCurrentRecord(_ record: ArchiveRecord) async {
        guard let deleteSource, deletable(record) else { fail(ArchiveError.unavailable); return }
        do {
            error = nil
            try await deleteSource(record); canUndoSourceDeletion = sourceUndo != nil
            await refresh()
            guard error == nil else { return }
            publishOutcome(recordsText("The selected source was deleted from this iPhone."))
        }
        catch { fail(error) }
    }
    func undoCurrentDeletion() async {
        guard let sourceUndo, canUndoSourceDeletion else { return }
        do { error = nil; try await sourceUndo(); canUndoSourceDeletion = false; await refresh(); if error == nil { publishOutcome(recordsText("Deletion undone.")) } } catch { fail(error) }
    }
    func reviewWholeLedgerDeletion() async {
        guard !busy, let wholeLedgerDeletionAction else { return }
        busy = true; defer { busy = false }
        do { try await wholeLedgerDeletionAction() }
        catch LedgerDeletionError.pendingSave {
            error = nil; status = recordsText("Retry or discard the pending shopping-list save before reviewing ledger deletion.")
        } catch { fail(error) }
    }
    /// Clear cached disclosures and pending imports before retiring a source. A new
    /// snapshot can only repopulate them after composition rechecks tombstones.
    func invalidateForSourceErasure() {
        recoveredOpenGeneration = UUID()
        preparedDocument = nil; recoveryKey = ""; selectedIDs = []; selectedMediaIDs = []
        review = nil; reviewAuthorization = nil; recipeReport = nil; lastImportIDs = []; deleteUndo = nil
        currentRecords = []; recoveredRecords = []; unavailableRecords = []; status = nil; actionOutcomeID = nil; error = nil
    }
    func dismissPreparedFile() { preparedDocument = nil }
    private func authorization() throws -> Authorization {
        guard let authorize = beginAuthorization(), authorize() else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
        return authorize
    }
    private func requireAuthorization(_ authorize: Authorization) throws {
        guard authorize() else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
    }
    func reportFileError(_ error: Error) { fail(error) }
    private func publishOutcome(_ text: String) {
        error = nil; status = text; actionOutcomeID = UUID()
    }
    private func fail(_ error: Error) {
        self.error = error as? ArchiveError ?? .unavailable
        status = nil; actionOutcomeID = nil
    }
}

func recordsText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Records") }

extension RecipeImportReport {
    var localizedSummary: String {
        let ready = recordsText(recipes.count == 1 ? "recipe ready" : "recipes ready")
        let duplicates = recordsText(duplicateCount == 1 ? "duplicate" : "duplicates")
        let skipped = recordsText(skippedRows == 1 ? "row skipped" : "rows skipped")
        return "\(recipes.count) \(ready) · \(duplicateCount) \(duplicates) · \(skippedRows) \(skipped)"
    }
    var localizedUnsupportedFields: String? {
        guard !unsupportedFields.isEmpty else { return nil }
        return recordsText("Unsupported fields: ") + unsupportedFields.joined(separator: ", ")
    }
}
