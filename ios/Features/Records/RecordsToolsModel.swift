import Foundation
import SwiftUI
import RecordArchive
import CoreDomain

struct RecordsSelectionID: Hashable {
    let origin: String
    let recordID: String
    let revision: String
    var source: ArchiveSourceIdentity { .init(origin: origin, recordID: recordID) }
    private static let personalProjection = ArchiveCodec.projection(for: .personalRecovery)
    var personalArchiveIdentity: ArchiveIdentity {
        .init(origin: origin, recordID: recordID, revision: revision, projection: Self.personalProjection)
    }
}

struct RecordsMediaSelectionID: Hashable {
    let record: RecordsSelectionID
    let attachmentID: String
}

struct RecordsImportSourceVersion: Identifiable, Equatable {
    let revision: String
    let savedAtMilliseconds: Int64
    var id: String { revision }
}

/// Native export/validation/open/delete are provided by the composition root. Validation
/// must decode and re-encode an allowlisted domain payload, never raw database/account data.
@MainActor final class RecordsToolsModel: ObservableObject {
    typealias Snapshot = @MainActor () async throws -> RecordsSnapshotBatch
    typealias Validate = (ArchiveRecord) async throws -> Void
    typealias Open = (RecoveredRecord) async throws -> Void
    typealias Delete = (ArchiveRecord, @escaping Authorization) async throws -> Void
    typealias Authorization = @MainActor @Sendable () -> Bool

    @Published private(set) var sourceListing = RecordsSnapshotBatch()
    var currentRecords: [ArchiveRecord] { sourceListing.records }
    @Published private(set) var recoveredRecords: [RecoveredRecord] = []
    var unavailableRecords: [RecordsUnavailableRecord] { sourceListing.unavailable }
    @Published private(set) var review: RecoveryReview?
    // An unreadable fresh listing cannot authorize a prior household comparison.
    private var verifiedLiveImportListing = false
    var currentImportVersions: [ArchiveIdentity: [RecordsImportSourceVersion]] {
        guard let review, review.envelope.documentKind == .personalRecovery, reviewAuthorization?() == true else { return [:] }
        var bySource: [ArchiveSourceIdentity: [RecordsImportSourceVersion]] = [:]
        for record in currentRecords where record.nativePayload != nil {
            let id = Self.selectionID(record)
            guard sourceListing.recoveredCopyIDsByRecord[id] == nil,
                  !sourceListing.liveSharedRecordIDs.contains(id) || verifiedLiveImportListing else { continue }
            bySource[id.source, default: []].append(.init(revision: record.revision, savedAtMilliseconds: record.savedAtMilliseconds))
        }
        var matches: [ArchiveIdentity: [RecordsImportSourceVersion]] = [:]
        for row in review.rows where row.disposition != .erased && row.record.nativePayload != nil {
            matches[row.id] = bySource[Self.selectionID(row.record).source]
        }
        return matches
    }
    @Published private(set) var recipeReport: RecipeImportReport?
    @Published private(set) var busy = false
    private struct ActionStatus {
        let text: String
        var reopenedCopyIDs: Set<String> = []
    }
    @Published private var actionStatus: ActionStatus?
    var status: String? { actionStatus?.text }
    var reopenedCopyIDs: Set<String> { actionStatus?.reopenedCopyIDs ?? [] }
    /// A completed model action supplies a new focus target; view state cannot
    /// announce success before the underlying operation has finished.
    @Published private(set) var actionOutcomeID: UUID?
    @Published private(set) var error: ArchiveError?
    @Published var selectedIDs: Set<RecordsSelectionID> = []
    /// Attachment disclosure is separate from record selection and defaults off.
    @Published var selectedMediaIDs: Set<RecordsMediaSelectionID> = []
    @Published var recoveryKey = "" {
        didSet {
            if recoveryKey != oldValue, preparedDocument?.kind == .recovery {
                dismissPreparedFile()
                actionStatus = nil
            }
        }
    }
    @Published private(set) var preparedDocument: RecordsFileDocument?
    @Published private var backupStatuses: [ArchiveIdentity: EncryptedBackupStatus] = [:]
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
    private let willRemoveRecovered: () -> Void
    private var recoveredOpenGeneration = UUID()
    private var liveSharedGeneration = UUID()
    private var preparedLiveIDs: Set<RecordsSelectionID> = []
    private struct ExportContext {
        let authorize: Authorization
        let backup: EncryptedBackupIntent?
    }
    private var exportContext: ExportContext?
    private var activeFileSave: (id: UUID, completing: Bool)?
    private var retiredHistories: Set<ArchiveSourceIdentity> = []
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
    var supportText: String { ReadableArchive.supportReport(error: error, recordCount: currentRecords.count + recoveredRecords.count, locale: recordsInterfaceLocale) }
    nonisolated static func selectionID(_ record: ArchiveRecord) -> RecordsSelectionID {
        RecordsSelectionID(origin: record.origin, recordID: record.id, revision: record.revision)
    }
    static func mediaSelectionID(_ media: ArchiveMediaAttachment, record: ArchiveRecord) -> RecordsMediaSelectionID {
        RecordsMediaSelectionID(record: selectionID(record), attachmentID: media.id)
    }

    init(registry: RecoveryRegistry, snapshot: @escaping Snapshot, validateNativePayload: @escaping Validate,
         openRecovered: @escaping Open, deleteSource: Delete? = nil, undoSourceDeletion: (() async throws -> Void)? = nil, canDeleteSource: @escaping (ArchiveRecord) -> Bool = { _ in true }, cleanupRecoveredWorkspaces: (() async throws -> Void)? = nil, willRemoveRecovered: @escaping () -> Void = {}, reviewWholeLedgerDeletion: (() async throws -> Void)? = nil, beginAuthorization: @escaping () -> Authorization? = { { true } }) {
        self.registry = registry; self.snapshot = snapshot; self.validate = validateNativePayload
        self.open = openRecovered; self.deleteSource = deleteSource; self.sourceUndo = undoSourceDeletion; self.deletable = canDeleteSource; self.cleanupRecovered = cleanupRecoveredWorkspaces; self.wholeLedgerDeletionAction = reviewWholeLedgerDeletion
        self.beginAuthorization = beginAuthorization
        self.willRemoveRecovered = willRemoveRecovered
    }
    func liveSharedAccessEnded() {
        liveSharedGeneration = UUID()
        if !preparedLiveIDs.isEmpty { dismissPreparedFile(); actionStatus = nil }
        var listing = sourceListing
        let retired = listing.liveSharedRecordIDs
        guard !retired.isEmpty else { return }
        listing.records.removeAll { retired.contains(Self.selectionID($0)) }
        listing.householdFetchedAtMilliseconds.removeAll()
        for id in retired { backupStatuses.removeValue(forKey: id.personalArchiveIdentity) }
        listing.liveSharedRecordIDs = []
        sourceListing = listing
        selectedIDs.subtract(retired)
    }
    func liveHistoryRetired(_ source: ArchiveSourceIdentity) {
        retiredHistories.insert(source)
        if preparedLiveIDs.contains(where: { $0.source == source }) { dismissPreparedFile(); actionStatus = nil }
        var listing = sourceListing
        let removed = listing.liveSharedRecordIDs.filter { $0.source == source }
        guard !removed.isEmpty else { return }
        listing.records.removeAll { removed.contains(Self.selectionID($0)) }
        for id in removed {
            listing.householdFetchedAtMilliseconds.removeValue(forKey: id)
            backupStatuses.removeValue(forKey: id.personalArchiveIdentity)
        }
        listing.liveSharedRecordIDs.subtract(removed)
        sourceListing = listing
        selectedIDs.subtract(removed)
    }
    private func containsRetiredHistory(_ liveIDs: Set<RecordsSelectionID>) -> Bool {
        liveIDs.contains { retiredHistories.contains($0.source) }
    }
    private func publishListing(_ batch: RecordsSnapshotBatch, startedIn generation: UUID,
                                backups: [ArchiveIdentity: EncryptedBackupStatus]? = nil) {
        // Independent recovered records can share an identity with a denied live record.
        // Only a batch carrying an older live read is invalidated by that denial.
        guard !containsRetiredHistory(batch.liveSharedRecordIDs) else { return }
        if generation == liveSharedGeneration || batch.liveSharedRecordIDs.isEmpty {
            if let backups {
                backupStatuses = backups
            } else if sourceListing.recoveredCopyIDsByRecord != batch.recoveredCopyIDsByRecord {
                backupStatuses = [:]
            }
            verifiedLiveImportListing = true
            sourceListing = batch
        }
    }
    private func reloadListing(authorize: Authorization) async throws {
        let generation = liveSharedGeneration
        let batch = try await snapshot()
        try requireAuthorization(authorize)
        let listing = try await registry.refreshList(includingBackupsFor: batch.records, recoveredCopyIDs: batch.backupCopyIDs)
        try requireAuthorization(authorize)
        publishListing(batch, startedIn: generation, backups: listing.backups)
        recoveredRecords = listing.recovered
    }
    func refresh() async {
        do {
            let authorize = try authorization()
            try await reloadListing(authorize: authorize)
            selectedIDs.formIntersection(Set(currentRecords.map(Self.selectionID)))
            selectedMediaIDs.formIntersection(Set(currentRecords.flatMap { record in (record.media ?? []).map { Self.mediaSelectionID($0, record: record) } }))
        } catch { fail(error) }
    }
    func selectAll() { selectedIDs = Set(currentRecords.map(Self.selectionID)) }
    func generateRecoveryKey() { recoveryKey = EncryptedArchive.generateKey() }
    enum ExportChoice { case encryptedRecovery, helperJSON, helperText, ownerText }
    func prepareExport(_ choice: ExportChoice) async {
        guard !busy else { return }
        busy = true; error = nil; dismissPreparedFile()
        defer { busy = false }
        do {
            let authorize = try authorization()
            let generation = liveSharedGeneration
            let requested = selectedIDs
            let mediaSelection = selectedMediaIDs
            let selectedKey = recoveryKey
            // Photo references can change independently of the ledger revision.
            // Retain the disclosed attachment bytes until the fresh listing is checked.
            func selectedAttachments(in records: [ArchiveRecord]) -> [RecordsMediaSelectionID: ArchiveMediaAttachment] {
                guard choice == .encryptedRecovery else { return [:] }
                var attachments: [RecordsMediaSelectionID: ArchiveMediaAttachment] = [:]
                for record in records where requested.contains(Self.selectionID(record)) {
                    for media in record.media ?? [] {
                        let id = Self.mediaSelectionID(media, record: record)
                        if mediaSelection.contains(id) { attachments[id] = media }
                    }
                }
                return attachments
            }
            let disclosed = selectedAttachments(in: currentRecords)
            let previouslyLive = requested.intersection(sourceListing.liveSharedRecordIDs)
            let batch = try await snapshot()
            try requireAuthorization(authorize)
            let requestedLive = !requested.isDisjoint(with: batch.liveSharedRecordIDs)
            guard !containsRetiredHistory(previouslyLive), !containsRetiredHistory(batch.liveSharedRecordIDs),
                  generation == liveSharedGeneration || (previouslyLive.isEmpty && !requestedLive) else { throw ArchiveError.staleReview }
            publishListing(batch, startedIn: generation)
            let available = Set(batch.records.map(Self.selectionID))
            let refreshedMedia = selectedAttachments(in: batch.records)
            guard requested == selectedIDs, requested.isSubset(of: available), disclosed == refreshedMedia else {
                selectedIDs.formIntersection(available)
                let changedMedia = Set(disclosed.keys).union(refreshedMedia.keys).filter { disclosed[$0] != refreshedMedia[$0] }
                selectedMediaIDs.subtract(changedMedia)
                throw ArchiveError.exportSelectionChanged
            }
            let liveIDs = requested.intersection(batch.liveSharedRecordIDs)
            let records = batch.records.filter { requested.contains(Self.selectionID($0)) }.map { source -> ArchiveRecord in
                var record = source
                record.media = choice == .encryptedRecovery ? source.media?.filter { disclosed[Self.mediaSelectionID($0, record: source)] != nil } : nil
                if record.media?.isEmpty == true { record.media = nil }
                return record
            }
            guard !records.isEmpty else { throw ArchiveError.unavailable }
            if choice == .helperJSON || choice == .helperText { guard records.count == 1 else { throw ArchiveError.unsupportedProjection } }
            for record in records { try await validateRecord(record); try requireAuthorization(authorize) }
            let document: RecordsFileDocument
            let name: String
            var backup: EncryptedBackupIntent?
            switch choice {
            case .encryptedRecovery, .helperJSON:
                let kind: ArchiveKind = choice == .encryptedRecovery ? .personalRecovery : .helperShop
                // Export identity depends on source revisions, not file creation time.
                let revision = ArchiveCodec.digest(try ArchiveCodec.canonical(records.map { [$0.origin, $0.id, $0.revision] }.sorted { $0.lexicographicallyPrecedes($1) }))
                let envelope = try ArchiveCodec.make(records: records, kind: kind, origin: "selected-local-records", revision: revision, shopID: kind == .helperShop ? records.first?.id : nil)
                let data = choice == .encryptedRecovery ? try EncryptedArchive.seal(envelope, key: selectedKey) : try ArchiveCodec.encode(envelope)
                document = RecordsFileDocument(data: data, kind: choice == .encryptedRecovery ? .recovery : .helper)
                name = choice == .encryptedRecovery ? "Personal-recovery" : "Helper-copy"
                if choice == .encryptedRecovery {
                    backup = try await registry.prepareEncryptedBackup(records, recoveredCopyIDs: batch.backupCopyIDs)
                }
            case .helperText, .ownerText:
                let bounded = try ArchiveCodec.make(records: records, kind: choice == .ownerText ? .personalRecovery : .helperShop,
                    origin: "selected-local-records", revision: "readable-preview")
                _ = try ArchiveCodec.encode(bounded)
                let readableRecords = choice == .helperText ? bounded.payload.records : records
                let text = try readableRecords.map { record in
                    try exportText(record, owner: choice == .ownerText)
                }.joined(separator: "\n\n")
                document = RecordsFileDocument(data: Data(text.utf8), kind: .text)
                name = choice == .ownerText ? "Private-readable-records" : "Cook-copy"
            }
            try requireAuthorization(authorize)
            guard !containsRetiredHistory(liveIDs), liveIDs.isEmpty || generation == liveSharedGeneration else { throw ArchiveError.staleReview }
            guard selectedIDs == requested,
                  choice != .encryptedRecovery || (selectedMediaIDs == mediaSelection && recoveryKey == selectedKey) else {
                throw ArchiveError.exportSelectionChanged
            }
            preparedLiveIDs = liveIDs
            preparedIsPrivate = choice == .encryptedRecovery || choice == .ownerText
            preparedName = name
            exportContext = ExportContext(authorize: authorize, backup: backup)
            preparedDocument = document
            actionStatus = ActionStatus(text: recordsText("Your file is ready to review and save."))
        } catch { fail(error, reveal: true) }
    }

    private func exportText(_ record: ArchiveRecord, owner: Bool) throws -> String {
        guard owner, let bytes = record.nativePayload else { return recordsReadableText(record, owner: owner) }
        let body: String
        switch record.kind {
        case .comparison:
            body = try RecordsNativeCodec.comparison(bytes).readableText()
        case .pickup:
            body = try PickupReadableRecord.text(RecordsNativeCodec.pickup(bytes), locale: recordsInterfaceLocale)
        case .ledger:
            body = try LedgerReadableRecord.text(bytes)
        case .recipe:
            return recordsReadableText(record, owner: true)
        case .sharedShop:
            return try SharedRecordArchiveAdapter.readable(record)
        case .sharedHistory:
            return try SharedHistoryArchiveAdapter.readable(record)
        }
        return ReadableArchive.heading(record, locale: recordsInterfaceLocale) + "\n" + body
    }

    enum ImportEntry { case recordsFile, recipeFile, manualRecipe }
    struct ImportPresentation: Identifiable {
        let id = UUID()
        let entry: ImportEntry
        fileprivate let authorize: Authorization
    }
    @Published private(set) var importPresentation: ImportPresentation?

    @discardableResult func beginImport(_ entry: ImportEntry) -> ImportPresentation? {
        guard !busy else { return nil }
        do {
            let presentation = ImportPresentation(entry: entry, authorize: try authorization())
            importPresentation = presentation
            return presentation
        } catch { fail(error); return nil }
    }
    func dismissImport(_ presentation: ImportPresentation) {
        if importPresentation?.id == presentation.id { importPresentation = nil }
    }
    private func accepts(_ presentation: ImportPresentation) -> Bool {
        guard importPresentation?.id == presentation.id else { return false }
        guard presentation.authorize() else { invalidateForSourceErasure(); return false }
        return true
    }
    func finishFileImport(_ result: Result<URL, Error>, from presentation: ImportPresentation) async {
        guard presentation.entry != .manualRecipe, accepts(presentation) else { return }
        dismissImport(presentation)
        switch result {
        case .success(let url):
            await importFile(url, recipes: presentation.entry == .recipeFile, authorize: presentation.authorize)
        case .failure(let error):
            if !Self.fileSelectionCancelled(error) { fail(error, reveal: true) }
        }
    }

    func importFile(_ url: URL, recipes: Bool) async {
        guard !busy else { return }
        do {
            let authorize = try authorization()
            await importFile(url, recipes: recipes, authorize: authorize)
        } catch { fail(error, reveal: true) }
    }
    private func importFile(_ url: URL, recipes: Bool, authorize: @escaping Authorization) async {
        guard !busy else { return }
        busy = true; review = nil; reviewAuthorization = nil; recipeReport = nil; error = nil
        defer { busy = false }
        do {
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
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ArchiveError.malformed
                }
                let envelope = object["algorithm"] != nil ? try EncryptedArchive.open(data, key: recoveryKey) : try ArchiveCodec.decode(data)
                try await stage(envelope, authorize: authorize)
            }
        } catch { fail(error, reveal: true) }
    }
    func stageManualRecipe(_ recipe: ImportedRecipe, from presentation: ImportPresentation) async -> Bool {
        guard !busy, presentation.entry == .manualRecipe, accepts(presentation) else { return false }
        busy = true; error = nil; review = nil; recipeReport = nil
        defer { busy = false }
        do {
            let authorize = presentation.authorize
            let record = try recipe.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0))
            try await stage(ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "recipe-library-v1", revision: recipe.id), authorize: authorize)
            return true
        } catch {
            fail(error)
            return false
        }
    }
    private var reviewAuthorization: Authorization?
    private func stage(_ envelope: ArchiveEnvelope, authorize: @escaping Authorization) async throws {
        for record in envelope.payload.records { try await validateRecord(record); try requireAuthorization(authorize) }
        let liveSources = Set(sourceListing.liveSharedRecordIDs.map(\.source))
        if envelope.documentKind == .personalRecovery,
           envelope.payload.records.contains(where: { $0.nativePayload != nil && liveSources.contains(Self.selectionID($0).source) }) {
            verifiedLiveImportListing = false
            do { try await reloadListing(authorize: authorize) }
            catch {
                try Task.checkCancellation()
                try requireAuthorization(authorize)
                // The file can still be reviewed without a fresh household comparison.
            }
        }
        let staged = try await registry.review(envelope)
        try requireAuthorization(authorize)
        reviewAuthorization = authorize
        review = staged
        actionStatus = nil
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
    private func discardImportReview() { review = nil; reviewAuthorization = nil; recipeReport = nil }
    func cancelReview() { discardImportReview(); publishOutcome(recordsText("Import cancelled. Your records are unchanged.")) }
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
            try await reloadListing(authorize: authorize)
            if result.records.isEmpty {
                publishOutcome(recordsText("This file contains no records to recover."))
            } else if result.insertedCount == 0 {
                let copyIDs = Set(result.records.map(\.id))
                guard copyIDs.isSubset(of: recoveredRecords.map(\.id)) else { throw ArchiveError.staleReview }
                publishOutcome(recordsText("Opened the existing recovered copies. Nothing was duplicated."), reopenedCopyIDs: copyIDs)
            } else {
                publishOutcome(recordsText("Saved separate recovered copies. Your current work is unchanged."))
            }
        } catch { fail(error) }
    }
    func undoImport() async {
        guard !lastImportIDs.isEmpty else { return }
        do {
            let authorize = try authorization()
            cancelRecoveredOpen()
            try await registry.undoImport(insertedCopyIDs: lastImportIDs); discardImportReview(); lastImportIDs = []; try await cleanupRecovered?()
            try requireAuthorization(authorize)
            try await reloadListing(authorize: authorize)
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
    struct DeletionReview: Identifiable {
        fileprivate enum Target {
            case source(ArchiveRecord), recovered(RecoveryDeletionReview)
        }
        let id = UUID()
        let title: String
        fileprivate let target: Target
        fileprivate let authorize: Authorization
        var copyCount: Int? {
            if case let .recovered(review) = target { return review.count }
            return nil
        }
    }
    func reviewRecoveredDeletion(_ scope: RecoveryDeleteScope, title: String) -> DeletionReview? {
        do {
            let authorize = try authorization()
            let copies = RecoveryDeletionReview(scope: scope, displayedCopies: recoveredRecords)
            guard copies.count > 0 else { throw ArchiveError.unavailable }
            return DeletionReview(title: title, target: .recovered(copies), authorize: authorize)
        } catch { fail(error, reveal: true); return nil }
    }
    func reviewSourceDeletion(_ record: ArchiveRecord) -> DeletionReview? {
        do {
            let authorize = try authorization()
            guard canDeleteSource(record), currentRecords.contains(where: { Self.selectionID($0) == Self.selectionID(record) }) else {
                throw ArchiveError.deletionSelectionChanged
            }
            return DeletionReview(title: recordsTitle(record), target: .source(record), authorize: authorize)
        } catch { fail(error, reveal: true); return nil }
    }
    func confirmDeletion(_ review: DeletionReview) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let authorize = review.authorize
            try requireAuthorization(authorize)
            let outcome: String
            switch review.target {
            case let .source(record):
                guard let deleteSource, deletable(record) else { throw ArchiveError.unavailable }
                try await deleteSource(record, authorize)
                canUndoSourceDeletion = sourceUndo != nil
                outcome = recordsText("The selected source was deleted from this iPhone.")
            case let .recovered(copies):
                cancelRecoveredOpen()
                let token = try await registry.delete(copies)
                if let cleanupRecovered {
                    deleteUndo = nil
                    await registry.discardUndo()
                    try await cleanupRecovered()
                    outcome = recordsText("The recovered copies and their separate workspaces were permanently deleted from this iPhone.")
                } else {
                    deleteUndo = token
                    outcome = recordsText("Deleted from this iPhone. Undo is available until you leave the app.")
                }
            }
            discardImportReview()
            try requireAuthorization(authorize)
            try await reloadListing(authorize: authorize)
            publishOutcome(outcome)
        }
        catch ArchiveError.deletionSelectionChanged {
            do {
                try requireAuthorization(review.authorize)
                try await reloadListing(authorize: review.authorize)
                fail(ArchiveError.deletionSelectionChanged, reveal: true)
            } catch { fail(error, reveal: true) }
        } catch { fail(error) }
    }
    func undoRecoveredDeletion() async {
        guard let token = deleteUndo else { return }
        do {
            let authorize = try authorization()
            try await registry.undoDelete(token)
            discardImportReview()
            deleteUndo = nil
            let recovered = try await registry.refreshList()
            try requireAuthorization(authorize)
            recoveredRecords = recovered
            publishOutcome(recordsText("Deletion undone."))
        } catch { fail(error) }
    }
    func undoCurrentDeletion() async {
        guard let sourceUndo, canUndoSourceDeletion else { return }
        do { error = nil; try await sourceUndo(); discardImportReview(); canUndoSourceDeletion = false; await refresh(); if error == nil { publishOutcome(recordsText("Deletion undone.")) } } catch { fail(error) }
    }
    func reviewWholeLedgerDeletion() async {
        guard !busy, let wholeLedgerDeletionAction else { return }
        busy = true; defer { busy = false }
        do { try await wholeLedgerDeletionAction() }
        catch LedgerDeletionError.pendingSave {
            error = nil; actionStatus = ActionStatus(text: recordsText("Retry or discard the pending shopping-list save before reviewing ledger deletion."))
        } catch { fail(error) }
    }
    /// Clear cached disclosures and pending imports before retiring a source. A new
    /// snapshot can only repopulate them after composition rechecks tombstones.
    func invalidateForSourceErasure() {
        importPresentation = nil
        recoveredOpenGeneration = UUID()
        dismissPreparedFile(); recoveryKey = ""; selectedIDs = []; selectedMediaIDs = []
        review = nil; reviewAuthorization = nil; recipeReport = nil; lastImportIDs = []; deleteUndo = nil; canUndoSourceDeletion = false
        sourceListing = RecordsSnapshotBatch(); recoveredRecords = []; backupStatuses = [:]; actionStatus = nil; actionOutcomeID = nil; error = nil
    }
    func dismissPreparedFile() {
        activeFileSave = nil
        exportContext = nil
        preparedDocument = nil
        preparedLiveIDs.removeAll()
    }

    func backupDateText(for record: ArchiveRecord) -> String? {
        guard record.nativePayload != nil, let status = backupStatuses[Self.selectionID(record).personalArchiveIdentity] else { return nil }
        return RecordsDatePresentation.encryptedBackupSavedAt(status.savedAtMilliseconds, currentRevision: status.revisions.contains(record.revision))
    }

    func beginFileSave() -> UUID? {
        guard preparedDocument != nil, let context = exportContext else { return nil }
        guard context.authorize() else { invalidateForSourceErasure(); return nil }
        let id = UUID()
        activeFileSave = (id, false)
        return id
    }

    func finishFileSave(_ id: UUID, result: Result<Void, Error>, at date: Date = .now) async {
        guard activeFileSave?.id == id, activeFileSave?.completing == false, let context = exportContext else { return }
        activeFileSave?.completing = true
        defer { if activeFileSave?.id == id { activeFileSave = nil } }
        guard context.authorize() else { invalidateForSourceErasure(); return }
        if case let .failure(error) = result {
            if Self.fileSelectionCancelled(error) {
                publishOutcome(recordsText("Save cancelled. Your file is still ready."))
            } else { fail(error, reveal: true) }
            return
        }
        guard let backup = context.backup else { publishOutcome(recordsText("File saved.")); return }
        do {
            try await registry.recordSuccessfulBackup(backup, savedAtMilliseconds: ArchiveCodec.milliseconds(date))
            let generation = liveSharedGeneration
            let updated = try await registry.lastEncryptedBackups(for: currentRecords, recoveredCopyIDs: sourceListing.backupCopyIDs)
            guard context.authorize(), activeFileSave?.id == id, generation == liveSharedGeneration else { return }
            backupStatuses = updated
            publishOutcome(recordsText("Encrypted recovery file saved."))
        } catch {
            guard context.authorize(), activeFileSave?.id == id else { return }
            publishOutcome(recordsText("File saved. Its backup date is unavailable on this iPhone."))
        }
    }

    private static func fileSelectionCancelled(_ error: Error) -> Bool {
        let underlying = error as NSError
        return error is CancellationError || (underlying.domain == NSCocoaErrorDomain && underlying.code == NSUserCancelledError)
    }
    private func authorization() throws -> Authorization {
        guard let authorize = beginAuthorization(), authorize() else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
        return authorize
    }
    private func requireAuthorization(_ authorize: Authorization) throws {
        guard authorize() else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
    }
    private func publishOutcome(_ text: String, reopenedCopyIDs: Set<String> = []) {
        error = nil
        actionStatus = ActionStatus(text: text, reopenedCopyIDs: reopenedCopyIDs)
        actionOutcomeID = UUID()
    }
    private func fail(_ error: Error, reveal: Bool = false) {
        self.error = error as? ArchiveError ?? .unavailable
        actionStatus = nil; actionOutcomeID = reveal ? UUID() : nil
    }
}

var recordsInterfaceLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }
func recordsReadableText(_ record: ArchiveRecord, owner: Bool, locale: Locale = recordsInterfaceLocale) -> String {
    let language = locale.language.languageCode?.identifier ?? "en"
    return ReadableArchive.text([record], owner: owner, locale: locale) { line in
        let literal = line.originalAmount
        guard let unit = UnitOfMeasure(rawValue: line.originalUnit) else {
            return [literal, line.originalUnit].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if let amount = try? ListQuantityParser.numericAmount(literal) {
            return pQuantity(literal, unit: unit, singular: amount == .one, language: language)
        }
        // List imports can retain the entire original ingredient, including its unit.
        var tokens = ListQuantityParser.itemTokens(literal)
        if let amount = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true) {
            if tokens.isEmpty { return pQuantity(literal, unit: unit, singular: amount == .one, language: language) }
            let writtenUnit = ListQuantityParser.takeUnit(from: &tokens)
            if writtenUnit == unit || (writtenUnit == nil && unit == .count) { return literal }
        }
        let label = pUnitLabel(unit, singular: false, language: language)
        return [literal, label].filter { !$0.isEmpty }.joined(separator: " · ")
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

/// Localize app-generated headings without changing archive identity or user wording.
func recordsTitle(_ record: ArchiveRecord) -> String {
    if record.kind == .sharedShop && record.title == "Shared pickup" { return recordsText("Shared pickup record") }
    if record.kind == .sharedHistory && record.title == "Shared pickup history" { return recordsText("Shared pickup history") }
    return record.title.isEmpty ? recordsText("Untitled record") : record.title
}
