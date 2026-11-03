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

    @Published private(set) var currentRecords: [ArchiveRecord] = []
    @Published private(set) var recoveredRecords: [RecoveredRecord] = []
    @Published private(set) var review: RecoveryReview?
    @Published private(set) var recipeReport: RecipeImportReport?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: ArchiveError?
    @Published var selectedIDs: Set<String> = []
    @Published var recoveryKey = ""
    @Published private(set) var preparedDocument: RecordsFileDocument?
    @Published private(set) var preparedName = "Room-in-the-Cart"
    @Published private(set) var preparedIsPrivate = false
    @Published private(set) var lastImportIDs: [String] = []
    @Published private(set) var deleteUndo: RecoveryUndoToken?
    let registry: RecoveryRegistry
    private let snapshot: Snapshot
    private let validate: Validate
    private let open: Open
    private let deleteSource: Delete?
    private let wholeLedgerDeletionAction: (() async throws -> Void)?
    private let cleanupRecovered: (() async throws -> Void)?
    private let deletable: (ArchiveRecord) -> Bool
    private let sourceUndo: (() async throws -> Void)?
    @Published private(set) var canUndoSourceDeletion = false
    private var selectedSnapshot: [ArchiveRecord] { currentRecords.filter { selectedIDs.contains(Self.selectionID($0)) } }
    var selectedCount: Int { selectedSnapshot.count }
    func canDeleteSource(_ record: ArchiveRecord) -> Bool { deleteSource != nil && deletable(record) }
    var canReviewWholeLedgerDeletion: Bool { wholeLedgerDeletionAction != nil }
    var recoveredDeletionAllowsUndo: Bool { cleanupRecovered == nil }
    var supportText: String { ReadableArchive.supportReport(error: error, recordCount: currentRecords.count + recoveredRecords.count) }
    static func selectionID(_ record: ArchiveRecord) -> String { record.origin + "/" + record.id + "/" + record.revision }

    init(registry: RecoveryRegistry, snapshot: @escaping Snapshot, validateNativePayload: @escaping Validate,
         openRecovered: @escaping Open, deleteSource: Delete? = nil, undoSourceDeletion: (() async throws -> Void)? = nil, canDeleteSource: @escaping (ArchiveRecord) -> Bool = { _ in true }, cleanupRecoveredWorkspaces: (() async throws -> Void)? = nil, reviewWholeLedgerDeletion: (() async throws -> Void)? = nil) {
        self.registry = registry; self.snapshot = snapshot; self.validate = validateNativePayload
        self.open = openRecovered; self.deleteSource = deleteSource; self.sourceUndo = undoSourceDeletion; self.deletable = canDeleteSource; self.cleanupRecovered = cleanupRecoveredWorkspaces; self.wholeLedgerDeletionAction = reviewWholeLedgerDeletion
    }
    func refresh() async {
        do {
            currentRecords = try await snapshot()
            recoveredRecords = try await registry.refreshList()
            selectedIDs.formIntersection(Set(currentRecords.map(Self.selectionID)))
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
            currentRecords = try await snapshot()
            let records = selectedSnapshot
            guard !records.isEmpty else { throw ArchiveError.unavailable }
            if choice == .helperJSON || choice == .helperText { guard records.count == 1 else { throw ArchiveError.unsupportedProjection } }
            for record in records { try await validateRecord(record) }
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
            status = recordsText("Your file is ready to review and save.")
        } catch { fail(error) }
    }
    func importFile(_ url: URL, recipes: Bool) async {
        guard !busy else { return }
        busy = true; review = nil; recipeReport = nil; error = nil
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try RecoveryRegistry.boundedRead(url)
            try ArchiveCodec.preflight(data)
            if recipes {
                let existing = try await registry.refreshList().compactMap { record -> ImportedRecipe? in
                    guard record.record.kind == .recipe, let bytes = record.record.nativePayload else { return nil }
                    return try? JSONDecoder().decode(ImportedRecipe.self, from: bytes)
                }
                let report = try RecipeImporter.stage(data, existing: existing)
                recipeReport = report
                let records = try report.recipes.map { try $0.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0)) }
                if records.isEmpty { status = recordsText("These recipes are already saved."); return }
                let envelope = try ArchiveCodec.make(records: records, kind: .personalRecovery, origin: "recipe-library-v1", revision: ArchiveCodec.digest(try ArchiveCodec.canonical(report.recipes)))
                try await stage(envelope)
            } else {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let envelope = object?["algorithm"] != nil ? try EncryptedArchive.open(data, key: recoveryKey) : try ArchiveCodec.decode(data)
                try await stage(envelope)
            }
        } catch { fail(error) }
    }
    func stageManualRecipe(_ recipe: ImportedRecipe) async {
        guard !busy else { return }
        busy = true; error = nil; review = nil; recipeReport = nil
        defer { busy = false }
        do {
            let record = try recipe.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0))
            try await stage(ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "recipe-library-v1", revision: recipe.id))
        } catch { fail(error) }
    }
    private func stage(_ envelope: ArchiveEnvelope) async throws {
        for record in envelope.payload.records { try await validateRecord(record) }
        review = try await registry.review(envelope)
        status = nil
    }
    private func validateRecord(_ record: ArchiveRecord) async throws {
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
    func cancelReview() { review = nil; recipeReport = nil; status = recordsText("Import cancelled. Your records are unchanged.") }
    func applyReviewedImport() async {
        guard !busy, let review else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            for record in review.envelope.payload.records { try await validateRecord(record) }
            let result = try await registry.apply(review)
            lastImportIDs = result.insertedCopyIDs
            self.review = nil; recipeReport = nil
            currentRecords = try await snapshot()
            recoveredRecords = try await registry.refreshList()
            status = result.insertedCount == 0 ? recordsText("Opened the existing recovered copies. Nothing was duplicated.") : recordsText("Saved separate recovered copies. Your current work is unchanged.")
        } catch { fail(error) }
    }
    func undoImport() async {
        guard !lastImportIDs.isEmpty else { return }
        do { try await registry.undoImport(insertedCopyIDs: lastImportIDs); lastImportIDs = []; try await cleanupRecovered?(); currentRecords = try await snapshot(); recoveredRecords = try await registry.refreshList(); status = recordsText("The imported batch was undone.") }
        catch { fail(error) }
    }
    func openRecovered(_ record: RecoveredRecord) async {
        do { try await open(record); if record.record.kind != .recipe { lastImportIDs = [] } } catch { fail(error) }
    }
    func deleteRecovered(_ scope: RecoveryDeleteScope) async {
        do {
            let token = try await registry.delete(scope)
            if let cleanupRecovered {
                deleteUndo = nil
                await registry.discardUndo()
                try await cleanupRecovered()
                status = recordsText("The recovered copies and their separate workspaces were permanently deleted from this iPhone.")
            } else {
                deleteUndo = token
                status = recordsText("Deleted from this iPhone. Undo is available until you leave the app.")
            }
            currentRecords = try await snapshot()
            recoveredRecords = try await registry.refreshList()
        }
        catch { fail(error) }
    }
    func undoRecoveredDeletion() async {
        guard let token = deleteUndo else { return }
        do { try await registry.undoDelete(token); deleteUndo = nil; recoveredRecords = try await registry.refreshList(); status = recordsText("Deletion undone.") } catch { fail(error) }
    }
    func deleteCurrentRecord(_ record: ArchiveRecord) async {
        guard let deleteSource, deletable(record) else { fail(ArchiveError.unavailable); return }
        do { try await deleteSource(record); canUndoSourceDeletion = sourceUndo != nil; await refresh(); status = recordsText("The selected source was deleted from this iPhone.") }
        catch { fail(error) }
    }
    func undoCurrentDeletion() async {
        guard let sourceUndo, canUndoSourceDeletion else { return }
        do { try await sourceUndo(); canUndoSourceDeletion = false; await refresh(); status = recordsText("Deletion undone.") } catch { fail(error) }
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
        preparedDocument = nil; recoveryKey = ""; selectedIDs = []
        review = nil; recipeReport = nil; lastImportIDs = []; deleteUndo = nil
        currentRecords = []; recoveredRecords = []; status = nil; error = nil
    }
    func dismissPreparedFile() { preparedDocument = nil }
    func reportFileError(_ error: Error) { fail(error) }
    private func fail(_ error: Error) {
        self.error = error as? ArchiveError ?? .unavailable
        status = nil
    }
}

func recordsText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Records") }
