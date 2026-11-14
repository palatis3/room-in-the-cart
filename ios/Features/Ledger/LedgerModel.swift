import Foundation
import Combine
import Darwin
import CoreDomain
import LocalStore

private struct LedgerDocument: Codable {
    let formatVersion: Int
    let workspace: LedgerWorkspace
}

private enum LedgerModelError: Error { case unsupportedDocument, noShop, notReady, pendingChange, mealScopeChanged, mealTemplateChanged }

/// Captured when an editor opens; a SwiftUI redraw must not replace its original scope.
struct LedgerMealEditContext {
    let workspaceID: UUID?
    let shopID: UUID?
    let template: MealTemplate?
    let chooseNow: Bool
}

struct LedgerMealSaveReview {
    let id = UUID()
    let context: LedgerMealEditContext
    let candidate: MealTemplate
}

struct WholeLedgerDeletionReview: Codable, Equatable {
    let workspaceID: UUID
    let revision: Int64
    let shopCount: Int
    let reusableDinnerCount: Int
}
enum LedgerDeletionError: Error { case unavailable, pendingDeletion, pendingSave, staleReview, invalidIntent }
private struct LedgerDeletionIntent: Codable, Equatable {
    let formatVersion: Int
    let review: WholeLedgerDeletionReview
    let operationID: UUID
    let requestedAt: Date
}

/// The content-free journal survives an uncertain store result and registry cleanup.
/// The same operation is retried after restart; a newer workspace is never targeted.
private enum LedgerDeletionJournal {
    static func withLock<T>(_ url: URL, _ action: () throws -> T) throws -> T {
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LedgerDeletionError.unavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LedgerDeletionError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
    static func readUnlocked(_ url: URL) throws -> LedgerDeletionIntent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard !data.isEmpty, data.count <= 4096 else { throw LedgerDeletionError.invalidIntent }
        let intent = try JSONDecoder().decode(LedgerDeletionIntent.self, from: data)
        guard intent.formatVersion == 1, intent.review.revision >= 0,
              (0...100).contains(intent.review.shopCount), (0...1000).contains(intent.review.reusableDinnerCount),
              intent.requestedAt.timeIntervalSinceReferenceDate.isFinite else { throw LedgerDeletionError.invalidIntent }
        return intent
    }
    static func read(_ url: URL) throws -> LedgerDeletionIntent? { try withLock(url) { try readUnlocked(url) } }
    static func create(_ intent: LedgerDeletionIntent, at url: URL) throws {
        try withLock(url) {
            guard try readUnlocked(url) == nil else { throw LedgerDeletionError.pendingDeletion }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(intent).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    static func remove(_ intent: LedgerDeletionIntent, at url: URL) throws {
        try withLock(url) {
            guard let existing = try readUnlocked(url) else { return }
            guard existing == intent else { throw LedgerDeletionError.invalidIntent }
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// UI drafts remain in their sheets. A candidate becomes visible only after the
/// store commits it; the receipt's exact bytes and operation ID survive retries.
@MainActor final class LedgerModel: ObservableObject {
    @Published private(set) var workspace = LedgerWorkspace() {
        didSet {
            if workspace.selectedShopID != oldValue.selectedShopID && !search.isEmpty {
                search = ""
            }
        }
    }
    @Published private(set) var savedAt: Date?
    @Published private(set) var saving = false
    @Published private(set) var opening = false
    @Published private(set) var ready = false
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var sourceWorkspaceID: UUID?
    @Published private(set) var hasPendingSave = false
    @Published private(set) var hasPendingLedgerDeletion = false
    @Published var error: String?
    @Published var search = ""
    private let databaseURL: URL?
    private let clock: () -> Date
    private var store: LedgerStore?
    private var committedPayload: Data?
    private var resolvedDatabaseURL: URL?
    private var pendingLedgerDeletion: LedgerDeletionIntent?
    var pendingLedgerDeletionReview: WholeLedgerDeletionReview? { pendingLedgerDeletion?.review }
    private var deletionJournalURL: URL? { resolvedDatabaseURL?.appendingPathExtension("erase-intent.json") }
    private struct PendingSave {
        let key: String
        let workspace: LedgerWorkspace
        let payload: Data
        let base: Int64
        let operationID: UUID
        let savedAt: Date
    }
    private var pending: PendingSave?

    init(databaseURL: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.databaseURL = databaseURL
        self.clock = clock
    }

    var shop: ShoppingLedger? {
        workspace.shops.first { $0.id == workspace.selectedShopID }
    }

    /// A backup contains only the last committed workspace, never a pending form.
    func exportPayload() throws -> Data {
        guard ready, !hasPendingLedgerDeletion else { throw LedgerModelError.notReady }
        try workspace.validate()
        if let committedPayload { return committedPayload }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LedgerDocument(formatVersion: 1, workspace: workspace))
    }

    nonisolated static func validatePayload(_ payload: Data) throws -> LedgerWorkspace {
        guard payload.count <= LedgerStore.maximumPayloadBytes else { throw LedgerModelError.unsupportedDocument }
        let document = try JSONDecoder().decode(LedgerDocument.self, from: payload)
        guard document.formatVersion == 1 else { throw LedgerModelError.unsupportedDocument }
        // LedgerWorkspace.init(from:) validates all decoded domain evidence.
        return document.workspace
    }

    func open() async {
        guard !ready, !opening else { return }
        opening = true
        defer { opening = false }
        do {
            let url: URL
            if let databaseURL { url = databaseURL }
            else {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                var directory = base.appendingPathComponent("RoomInTheCart", isDirectory: true)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    directory = base.appendingPathComponent("UITestWorkspace", isDirectory: true)
                }
                #endif
                url = directory.appendingPathComponent("ledger.sqlite")
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #if DEBUG
            if resolvedDatabaseURL == nil, ProcessInfo.processInfo.arguments.contains("--reset-test-workspace"), directory.lastPathComponent == "UITestWorkspace" {
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: url.path + suffix)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            }
            #endif
            resolvedDatabaseURL = url
            let opened = try LedgerStore(url: url)
            store = opened
            sourceWorkspaceID = opened.workspaceID
            if let intent = try LedgerDeletionJournal.read(url.appendingPathExtension("erase-intent.json")) {
                pendingLedgerDeletion = intent; hasPendingLedgerDeletion = true
                clearRetiredState()
                error = recordsText("A previously confirmed ledger deletion is pending. Open Data and recovery to retry it.")
                return
            }
            if let record = try await opened.load() {
                workspace = try Self.validatePayload(record.payload)
                committedPayload = record.payload
                revision = record.revision
                savedAt = record.savedAt
            }
            else {
                workspace = LedgerWorkspace(); committedPayload = nil; revision = 0; savedAt = nil
            }
            store = opened
            sourceWorkspaceID = opened.workspaceID
            ready = true
            error = nil
        } catch {
            self.error = ledgerText("Could not open your saved pickups. Try again. Existing data has not been replaced.")
        }
    }

    @discardableResult
    func change(key: String, _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        guard !saving, ready, !hasPendingLedgerDeletion else { return false }
        if pending != nil {
            error = ledgerText("Retry or discard the unsaved change before making another change.")
            return false
        }
        do {
            var candidate = workspace
            try edit(&candidate)
            try candidate.validate()
            guard candidate != workspace else { error = nil; return true }
            guard let store else { return false }
            // Reserve this revision while the immutable snapshot is encoded off the UI thread.
            saving = true
            defer { saving = false }
            let payload = try await Self.encodeForSave(candidate)
            guard payload.count <= LedgerStore.maximumPayloadBytes else {
                error = ledgerText("This change is too large to save. Reduce the amount of data and try again.")
                return false
            }
            let change = PendingSave(key: key, workspace: candidate, payload: payload, base: revision,
                                     operationID: UUID(), savedAt: clock())
            pending = change
            hasPendingSave = true
            return await commit(change, to: store)
        } catch LedgerModelError.mealScopeChanged {
            error = ledgerText("The pickup or workspace changed. Reopen the dinner for the pickup you want.")
            return false
        } catch LedgerModelError.mealTemplateChanged {
            error = ledgerText("Your reusable dinner changed. Reopen it to review the current version.")
            return false
        } catch LedgerError.stalePreview {
            error = ledgerText("This pickup changed after your preview. Return to the original text and review it again before adding it.")
            return false
        } catch LedgerError.allocationExceedsQuantity {
            error = ledgerText("That amount is already reserved or exceeds the existing quantity. Review the linked needs.")
            return false
        } catch LedgerError.incompatibleMatch {
            error = ledgerText("These items or units do not match, or the existing amount cannot supply this need.")
            return false
        } catch {
            self.error = ledgerText("Check the amounts, units and links. This change could not be applied; your saved pickup is unchanged.")
            return false
        }
    }

    func mealEditContext(template: MealTemplate?, chooseNow: Bool) -> LedgerMealEditContext {
        LedgerMealEditContext(workspaceID: sourceWorkspaceID, shopID: workspace.selectedShopID,
                              template: template, chooseNow: chooseNow)
    }

    func saveReviewedMeal(_ review: LedgerMealSaveReview) async -> Bool {
        let context = review.context, candidate = review.candidate
        return await change(key: "meal-editor-\(review.id)") { workspace in
            guard let workspaceID = context.workspaceID, sourceWorkspaceID == workspaceID,
                  workspace.selectedShopID == context.shopID else { throw LedgerModelError.mealScopeChanged }

            if context.chooseNow {
                guard let shopID = context.shopID,
                      let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw LedgerModelError.mealScopeChanged }
                // The original occurrence can have been edited or removed since a lost reply.
                if workspace.shops[index].mealOccurrences.contains(where: { $0.id == review.id }) { return }
                try workspace.shops[index].chooseMeal(candidate, occurrenceID: review.id)
            } else if let original = context.template {
                guard candidate.id == original.id,
                      let index = workspace.mealTemplates.firstIndex(where: { $0.id == original.id }) else { throw LedgerModelError.mealTemplateChanged }
                if workspace.mealTemplates[index] == candidate { return }
                guard workspace.mealTemplates[index] == original else { throw LedgerModelError.mealTemplateChanged }
                workspace.mealTemplates[index] = candidate
            } else {
                if workspace.mealTemplates.contains(candidate) { return }
                guard workspace.mealTemplates.isEmpty else { throw LedgerModelError.mealTemplateChanged }
                workspace.mealTemplates.append(candidate)
            }
        }
    }

    @discardableResult
    func editShop(key: String, shopID: UUID, _ edit: (inout ShoppingLedger) throws -> Void) async -> Bool {
        await change(key: key) { workspace in
            guard let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw LedgerModelError.noShop }
            try edit(&workspace.shops[index])
        }
    }

    @discardableResult
    func retrySave() async -> Bool {
        guard !saving, !hasPendingLedgerDeletion, let pending, let store else { return false }
        saving = true
        defer { saving = false }
        return await commit(pending, to: store)
    }

    @concurrent private static func encodeForSave(_ workspace: LedgerWorkspace) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LedgerDocument(formatVersion: 1, workspace: workspace))
    }

    private func commit(_ pending: PendingSave, to store: LedgerStore) async -> Bool {
        do {
            let record = try await store.save(payload: pending.payload, expectedRevision: pending.base,
                                              operationID: pending.operationID, savedAt: pending.savedAt)
            // No other mutation can start while saving, including during actor suspension.
            // Another store instance may have advanced after this operation's receipt.
            let current = try await store.load() ?? record
            // The pending value was fully validated before these exact bytes were
            // encoded. Reuse it only when the durable head is byte-for-byte equal;
            // another writer's payload still passes the complete decode/validation.
            let recovered = current.payload == pending.payload
                ? pending.workspace : try Self.validatePayload(current.payload)
            workspace = recovered
            committedPayload = current.payload
            revision = current.revision
            savedAt = current.savedAt
            self.pending = nil
            hasPendingSave = false
            error = nil
            return true
        } catch LedgerStoreError.erased {
            clearRetiredState()
            await open()
            self.error = recordsText("This ledger was deleted. Unsaved edits from its old workspace were discarded.")
            return false
        } catch LedgerStoreError.staleRevision(expected: _, actual: _) {
            self.error = ledgerText("A newer pickup is saved. Discard the pending save to reload it, then review your entries again.")
            return false
        } catch {
            self.error = ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
            return false
        }
    }

    /// Reload first, because an I/O interruption may hide a successful commit.
    func discardPendingSave() async {
        guard !saving, !hasPendingLedgerDeletion, let store else { return }
        saving = true
        defer { saving = false }
        do {
            if let record = try await store.load() {
                workspace = try Self.validatePayload(record.payload)
                committedPayload = record.payload
                revision = record.revision
                savedAt = record.savedAt
            }
            pending = nil
            hasPendingSave = false
            error = nil
        } catch LedgerStoreError.erased {
            clearRetiredState()
            await open()
            self.error = recordsText("This ledger was deleted. Unsaved edits from its old workspace were discarded.")
        } catch { self.error = ledgerText("Could not reload the saved pickup. Your pending change is still available to retry.") }
    }

    /// Only committed state participates in the review. Pending ordinary saves must
    /// first be resolved explicitly, rather than silently included in deletion.
    func reviewWholeLedgerDeletion() async throws -> WholeLedgerDeletionReview {
        if let pendingLedgerDeletion { return pendingLedgerDeletion.review }
        guard pending == nil else { throw LedgerDeletionError.pendingSave }
        guard ready, !saving, !opening, pending == nil, let store else { throw LedgerDeletionError.unavailable }
        let current = try await store.load()
        let source = try current.map { try Self.validatePayload($0.payload) } ?? LedgerWorkspace()
        return WholeLedgerDeletionReview(workspaceID: store.workspaceID, revision: current?.revision ?? 0,
            shopCount: source.shops.count, reusableDinnerCount: Set(source.mealTemplates.map(\.id) + source.dinnerPlanning.acceptedDinners.map { $0.template.id }).count)
    }
    func retiredLedgerWorkspaceIDs() async throws -> [UUID] {
        guard let store else { throw LedgerDeletionError.unavailable }
        return try await store.retiredWorkspaceIDs()
    }
    @discardableResult
    func eraseWholeLedger(_ review: WholeLedgerDeletionReview) async throws -> LedgerWorkspaceTombstone {
        if pendingLedgerDeletion != nil { return try await retryWholeLedgerDeletion() }
        guard ready, !saving, !opening, pending == nil, let journal = deletionJournalURL else { throw LedgerDeletionError.unavailable }
        let intent = LedgerDeletionIntent(formatVersion: 1, review: review, operationID: UUID(), requestedAt: clock())
        do { try LedgerDeletionJournal.create(intent, at: journal) }
        catch {
            // Another model may already have persisted a confirmed intent.
            if let existing = try? LedgerDeletionJournal.read(journal) {
                pendingLedgerDeletion = existing; hasPendingLedgerDeletion = true; clearRetiredState()
            }
            throw error
        }
        pendingLedgerDeletion = intent; hasPendingLedgerDeletion = true
        clearRetiredState()
        return try await retryWholeLedgerDeletion()
    }
    @discardableResult
    func retryWholeLedgerDeletion() async throws -> LedgerWorkspaceTombstone {
        guard !saving, !opening, let intent = pendingLedgerDeletion,
              let url = resolvedDatabaseURL, let journal = deletionJournalURL else { throw LedgerDeletionError.unavailable }
        saving = true; defer { saving = false }
        do {
            // Reopen even after an uncertain result: the old actor may be retired.
            let current = try LedgerStore(url: url)
            let receipt = try await current.eraseWorkspace(workspaceID: intent.review.workspaceID,
                expectedRevision: intent.review.revision, operationID: intent.operationID, at: intent.requestedAt)
            try await current.close()
            clearRetiredState()
            let replacement = try LedgerStore(url: url)
            store = replacement; sourceWorkspaceID = replacement.workspaceID
            error = nil
            // Keep the journal until Records confirms erasure markers and orphan cleanup.
            return receipt
        } catch LedgerStoreError.erased {
            // Another authorized local instance may already have retired this source.
            // Reconcile its receipt without ever applying deletion to the replacement.
            let current = try LedgerStore(url: url)
            guard let receipt = try await current.tombstones().first(where: {
                $0.workspaceID == intent.review.workspaceID && $0.erasedRevision >= intent.review.revision
            }) else { throw LedgerDeletionError.invalidIntent }
            store = current; sourceWorkspaceID = current.workspaceID
            clearRetiredState()
            return receipt
        } catch LedgerStoreError.staleRevision(expected: _, actual: _) {
            try LedgerDeletionJournal.remove(intent, at: journal)
            pendingLedgerDeletion = nil; hasPendingLedgerDeletion = false
            clearRetiredState()
            await open()
            error = recordsText("The ledger changed after review. Nothing was deleted. Review the entire ledger again.")
            throw LedgerDeletionError.staleReview
        } catch {
            clearRetiredState()
            self.error = recordsText("Ledger deletion is pending. Retry the same confirmed deletion in Data and recovery.")
            throw error
        }
    }
    /// Called only after origin-wide recovery markers and native orphan cleanup succeed.
    func finishWholeLedgerDeletion() async throws {
        guard !saving, !opening, let intent = pendingLedgerDeletion,
              let journal = deletionJournalURL, let store else { throw LedgerDeletionError.unavailable }
        saving = true; defer { saving = false }
        let tombstones = try await store.tombstones()
        guard tombstones.contains(where: { $0.workspaceID == intent.review.workspaceID && $0.erasedRevision >= intent.review.revision }) else { throw LedgerDeletionError.invalidIntent }
        let record = try await store.load()
        let replacement = try record.map { try Self.validatePayload($0.payload) } ?? LedgerWorkspace()
        try LedgerDeletionJournal.remove(intent, at: journal)
        workspace = replacement; committedPayload = record?.payload
        revision = record?.revision ?? 0; savedAt = record?.savedAt; sourceWorkspaceID = store.workspaceID
        pending = nil; hasPendingSave = false; pendingLedgerDeletion = nil; hasPendingLedgerDeletion = false
        ready = true; search = ""; error = nil
    }
    private func clearRetiredState() {
        workspace = LedgerWorkspace(); committedPayload = nil; revision = 0; savedAt = nil
        pending = nil; hasPendingSave = false; ready = false; search = ""
    }

    func startShop(title: String) async -> Bool {
        await change(key: "start-shop") { workspace in
            let shop = ShoppingLedger(title: title)
            workspace.shops.append(shop)
            workspace.selectedShopID = shop.id
        }
    }

    func selectShop(_ id: UUID) async {
        _ = await change(key: "select-\(id)") { $0.selectedShopID = id }
    }
}
