import Foundation
import SwiftUI
import RecordArchive
import CoreDomain

struct RecordsSelectionID: Hashable {
    let origin: String
    let recordID: String
    let revision: String
    var source: ArchiveSourceIdentity { .init(origin: origin, recordID: recordID) }
}

struct RecordsMediaSelectionID: Hashable {
    let record: RecordsSelectionID
    let attachmentID: String
}

/// Native export/validation/open/delete are provided by the composition root. Validation
/// must decode and re-encode an allowlisted domain payload, never raw database/account data.
@MainActor final class RecordsToolsModel: ObservableObject {
    typealias Snapshot = @MainActor () async throws -> RecordsSnapshotBatch
    typealias Validate = (ArchiveRecord) async throws -> Void
    typealias Open = (RecoveredRecord) async throws -> Void
    typealias Delete = (ArchiveRecord) async throws -> Void
    typealias Authorization = @MainActor @Sendable () -> Bool

    @Published private(set) var sourceListing = RecordsSnapshotBatch()
    var currentRecords: [ArchiveRecord] { sourceListing.records }
    @Published private(set) var recoveredRecords: [RecoveredRecord] = []
    var unavailableRecords: [RecordsUnavailableRecord] { sourceListing.unavailable }
    @Published private(set) var review: RecoveryReview?
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
        listing.liveSharedRecordIDs.subtract(removed)
        sourceListing = listing
        selectedIDs.subtract(removed)
    }
    private func containsRetiredHistory(_ liveIDs: Set<RecordsSelectionID>) -> Bool {
        liveIDs.contains { retiredHistories.contains($0.source) }
    }
    private func publishListing(_ batch: RecordsSnapshotBatch, startedIn generation: UUID) {
        // Independent recovered records can share an identity with a denied live record.
        // Only a batch carrying an older live read is invalidated by that denial.
        guard !containsRetiredHistory(batch.liveSharedRecordIDs) else { return }
        if generation == liveSharedGeneration || batch.liveSharedRecordIDs.isEmpty { sourceListing = batch }
    }
    private func reloadListing(authorize: Authorization) async throws {
        let generation = liveSharedGeneration
        let batch = try await snapshot()
        try requireAuthorization(authorize)
        let recovered = try await registry.refreshList()
        try requireAuthorization(authorize)
        publishListing(batch, startedIn: generation)
        recoveredRecords = recovered
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
            let previouslyLive = requested.intersection(sourceListing.liveSharedRecordIDs)
            let batch = try await snapshot()
            try requireAuthorization(authorize)
            let requestedLive = !requested.isDisjoint(with: batch.liveSharedRecordIDs)
            guard !containsRetiredHistory(previouslyLive), !containsRetiredHistory(batch.liveSharedRecordIDs),
                  generation == liveSharedGeneration || (previouslyLive.isEmpty && !requestedLive) else { throw ArchiveError.staleReview }
            publishListing(batch, startedIn: generation)
            let selected = requested.intersection(selectedIDs)
            let liveIDs = selected.intersection(batch.liveSharedRecordIDs)
            let records = batch.records.filter { selected.contains(Self.selectionID($0)) }.map { source -> ArchiveRecord in
                var record = source
                record.media = choice == .encryptedRecovery ? source.media?.filter { selectedMediaIDs.contains(Self.mediaSelectionID($0, record: source)) } : nil
                if record.media?.isEmpty == true { record.media = nil }
                return record
            }
            guard !records.isEmpty else { throw ArchiveError.unavailable }
            if choice == .helperJSON || choice == .helperText { guard records.count == 1 else { throw ArchiveError.unsupportedProjection } }
            for record in records { try await validateRecord(record); try requireAuthorization(authorize) }
            let document: RecordsFileDocument
            let name: String
            switch choice {
            case .encryptedRecovery, .helperJSON:
                let kind: ArchiveKind = choice == .encryptedRecovery ? .personalRecovery : .helperShop
                // Export identity depends on source revisions, not file creation time.
                let revision = ArchiveCodec.digest(try ArchiveCodec.canonical(records.map { [$0.origin, $0.id, $0.revision] }.sorted { $0.lexicographicallyPrecedes($1) }))
                let envelope = try ArchiveCodec.make(records: records, kind: kind, origin: "selected-local-records", revision: revision, shopID: kind == .helperShop ? records.first?.id : nil)
                let data = choice == .encryptedRecovery ? try EncryptedArchive.seal(envelope, key: recoveryKey) : try ArchiveCodec.encode(envelope)
                document = RecordsFileDocument(data: data, kind: choice == .encryptedRecovery ? .recovery : .helper)
                name = choice == .encryptedRecovery ? "Personal-recovery" : "Helper-copy"
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
            preparedLiveIDs = liveIDs
            preparedIsPrivate = choice == .encryptedRecovery || choice == .ownerText
            preparedName = name
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
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ArchiveError.malformed
                }
                let envelope = object["algorithm"] != nil ? try EncryptedArchive.open(data, key: recoveryKey) : try ArchiveCodec.decode(data)
                try await stage(envelope, authorize: authorize)
            }
        } catch { fail(error, reveal: true) }
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
            try await registry.undoImport(insertedCopyIDs: lastImportIDs); lastImportIDs = []; try await cleanupRecovered?()
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
            try await reloadListing(authorize: authorize)
            publishOutcome(outcome)
        }
        catch { fail(error) }
    }
    func undoRecoveredDeletion() async {
        guard let token = deleteUndo else { return }
        do {
            let authorize = try authorization()
            try await registry.undoDelete(token)
            deleteUndo = nil
            let recovered = try await registry.refreshList()
            try requireAuthorization(authorize)
            recoveredRecords = recovered
            publishOutcome(recordsText("Deletion undone."))
        } catch { fail(error) }
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
            error = nil; actionStatus = ActionStatus(text: recordsText("Retry or discard the pending shopping-list save before reviewing ledger deletion."))
        } catch { fail(error) }
    }
    /// Clear cached disclosures and pending imports before retiring a source. A new
    /// snapshot can only repopulate them after composition rechecks tombstones.
    func invalidateForSourceErasure() {
        recoveredOpenGeneration = UUID()
        dismissPreparedFile(); recoveryKey = ""; selectedIDs = []; selectedMediaIDs = []
        review = nil; reviewAuthorization = nil; recipeReport = nil; lastImportIDs = []; deleteUndo = nil
        sourceListing = RecordsSnapshotBatch(); recoveredRecords = []; actionStatus = nil; actionOutcomeID = nil; error = nil
    }
    func dismissPreparedFile() { preparedDocument = nil; preparedLiveIDs.removeAll() }
    private func authorization() throws -> Authorization {
        guard let authorize = beginAuthorization(), authorize() else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
        return authorize
    }
    private func requireAuthorization(_ authorize: Authorization) throws {
        guard authorize() else { invalidateForSourceErasure(); throw ArchiveError.unavailable }
    }
    func reportFileError(_ error: Error) { fail(error, reveal: true) }
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
