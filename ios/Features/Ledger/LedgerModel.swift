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
    let draftTokens: [UUID]? // Absent only in deletion journals written before drafts were reviewed.
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
        let tokens = intent.review.draftTokens
        guard (intent.formatVersion == 1 && tokens == nil) || (intent.formatVersion == 2 && tokens != nil),
              (tokens?.count ?? 0) <= 32, intent.review.revision >= 0,
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
    private let inventoryProjectionsEnabled: Bool
    private let mutationGate: PantryMutationGate?
    private let usesLivePantry: Bool
    // The ledger opens before the adult's paired pantry finishes authorization.
    // Private entry controls observe this model to become available after binding.
    @Published private var privatePantryAuthorization: (() -> Bool)?
    private var privatePantryDeletionCheck: (() throws -> Bool)?
    private var privatePantryWritable: Bool { !usesLivePantry || privatePantryAuthorization?() == true }
    @Published private(set) var hasPendingPantryProjection = false
    private var pendingPantryProjection: PantryLedgerProjectionPort.ValidatedSource?
    private var pantryPackPort: PantryPackSelectionCommitPort?
    @Published private(set) var pendingPantryPack: PantryPackSelectionPendingStore.Entry?
    private var pantryPackWasCommitted = false
    private var store: LedgerStore?
    private var committedPayload: Data?
    private var resolvedDatabaseURL: URL?
    private var pendingLedgerDeletion: LedgerDeletionIntent?
    var pendingLedgerDeletionReview: WholeLedgerDeletionReview? { pendingLedgerDeletion?.review }
    private var deletionJournalURL: URL? { resolvedDatabaseURL?.appendingPathExtension("erase-intent.json") }
    private struct PendingSave {
        var firstListDraft: FirstListDraftVersion? = nil
        let onShopSelected: ((UUID) -> Void)?
        let key: String
        let workspace: LedgerWorkspace
        let payload: Data
        let base: Int64
        let operationID: UUID
        let savedAt: Date
        let reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis?
        let authorize: (@MainActor () -> Bool)?
    }
    private var pending: PendingSave?

    init(databaseURL: URL? = nil, clock: @escaping () -> Date = Date.init,
         inventoryProjectionsEnabled: Bool = false, mutationGate: PantryMutationGate? = nil,
         pantryPackPort: PantryPackSelectionCommitPort? = nil, usesLivePantry: Bool = false) {
        self.databaseURL = databaseURL
        self.clock = clock
        self.inventoryProjectionsEnabled = inventoryProjectionsEnabled
        self.mutationGate = mutationGate
        self.pantryPackPort = pantryPackPort
        self.usesLivePantry = usesLivePantry
    }

    func pantryBackingStore(gate: PantryMutationGate) -> LedgerStore? {
        guard ready, !hasPendingLedgerDeletion, inventoryProjectionsEnabled, mutationGate === gate,
              let store, sourceWorkspaceID == store.workspaceID else { return nil }
        return store
    }

    func suspendPrivatePantryBinding() {
        guard usesLivePantry else { return }
        privatePantryAuthorization = nil
        privatePantryDeletionCheck = nil
        pantryPackPort = nil
        pendingPantryPack = nil; pantryPackWasCommitted = false
        hasPendingSave = pending != nil
    }

    func bindPrivatePantryRecovery(_ port: PantryPackSelectionCommitPort?, authorize: @escaping () -> Bool,
                                   allowLedgerErasure: @escaping () throws -> Bool) async throws {
        guard usesLivePantry, authorize() else { throw LedgerModelError.notReady }
        if let port, pantryPackPort !== port || privatePantryAuthorization == nil {
            try requirePantryPackPort(port)
            if try port.readPending() != nil { try await configurePantryPackRecovery(port) }
            else { pantryPackPort = port }
        }
        guard authorize() else { throw LedgerModelError.notReady }
        privatePantryAuthorization = authorize
        privatePantryDeletionCheck = allowLedgerErasure
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
            let opened = try LedgerStore(url: url, inventoryProjectionsEnabled: inventoryProjectionsEnabled)
            store = opened
            sourceWorkspaceID = opened.workspaceID
            if let port = pantryPackPort {
                try requirePantryPackPort(port)
                guard port.hasReadAccess else { throw PantryPackSelectionCommitPort.Failure.unauthorized }
            }
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
            if let port = pantryPackPort {
                try requirePantryPackPort(port)
                pendingPantryPack = try port.readPending()
                hasPendingSave = pendingPantryPack != nil
                try adoptPantryPack(try await port.recover(pendingPantryPack), using: port)
            }
            ready = true
            if !hasPendingSave { error = nil }
        } catch {
            if pantryPackPort != nil { pantryPackFailed(error) }
            self.error = ledgerText("Could not open your saved pickups. Try again. Existing data has not been replaced.")
        }
    }

    @discardableResult
    func saveMealPreferences(_ settings: MealPreferenceSettings, expectedRevision: UUID?, workspaceID: UUID,
                             authorize: @escaping @MainActor () -> Bool) async -> Bool {
        await change(key: "meal-preferences", onShopSelected: nil, authorize: authorize) { candidate in
            guard self.sourceWorkspaceID == workspaceID else { throw LedgerModelError.notReady }
            try candidate.dinnerPlanning.updateMealPreferences(settings, expectedRevision: expectedRevision)
        }
    }

    func change(key: String, _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        await change(key: key, onShopSelected: nil, edit)
    }

    func change(key: String, reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis?,
                _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        await change(key: key, onShopSelected: nil, reviewedPantryBasis: reviewedPantryBasis, edit)
    }

    func change(key: String, reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis?,
                authorize: @escaping @MainActor () -> Bool,
                _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        await change(key: key, onShopSelected: nil, reviewedPantryBasis: reviewedPantryBasis, authorize: authorize, edit)
    }

    private func change(key: String, onShopSelected: ((UUID) -> Void)?,
                        firstListDraft: FirstListDraftVersion? = nil,
                        reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis? = nil,
                        authorize: (@MainActor () -> Bool)? = nil,
                        _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        guard privatePantryWritable, !saving, ready, !hasPendingLedgerDeletion, !hasPendingPantryProjection, pendingPantryPack == nil else { return false }
        let originalAccess = privatePantryAuthorization
        let actionAccess: (@MainActor () -> Bool)?
        if usesLivePantry { actionAccess = { originalAccess?() == true && authorize?() != false } }
        else { actionAccess = authorize }
        if pending != nil {
            error = ledgerText("Retry or discard the unsaved change before making another change.")
            return false
        }
        do {
            let exclusive = reviewedPantryBasis != nil
            let lease = try exclusive ? mutationGate?.beginExclusiveWrite() : mutationGate?.beginWrite()
            defer { if let lease {
                if exclusive { mutationGate?.endExclusiveWrite(lease) } else { mutationGate?.endWrite(lease) }
            } }
            guard actionAccess?() != false else { throw LedgerModelError.notReady }
            var candidate = workspace
            try edit(&candidate)
            candidate.listLayout.applyDepartmentMemory(to: candidate.shops, previous: workspace.shops)
            candidate.discardOrphanedMealFeedback()
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
            if let basis = reviewedPantryBasis { try await verifyPantryBasis(basis) }
            guard actionAccess?() != false else { throw LedgerModelError.notReady }
            let change = PendingSave(firstListDraft: firstListDraft, onShopSelected: onShopSelected, key: key, workspace: candidate, payload: payload, base: revision,
                                     operationID: firstListDraft?.token ?? UUID(), savedAt: clock(), reviewedPantryBasis: reviewedPantryBasis, authorize: actionAccess)
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
            if reviewedPantryBasis != nil, pantryPackPort?.hasReadAccess == false { clearRetiredState() }
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
    func editShop(key: String, shopID: UUID, authorize: (@MainActor () -> Bool)? = nil,
                  _ edit: (inout ShoppingLedger) throws -> Void) async -> Bool {
        await change(key: key, onShopSelected: nil, authorize: authorize) { workspace in
            guard let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw LedgerModelError.noShop }
            try edit(&workspace.shops[index])
        }
    }

    @discardableResult
    func retrySave() async -> Bool {
        guard privatePantryWritable else { return false }
        if pendingPantryPack != nil { return await recoverPantryPack(commitIfUnapplied: true) }
        guard !saving, !hasPendingLedgerDeletion, !hasPendingPantryProjection, let pending, let store else { return false }
        saving = true
        defer { saving = false }
        do {
            let exclusive = pending.reviewedPantryBasis != nil
            let lease = try exclusive ? mutationGate?.beginExclusiveWrite() : mutationGate?.beginWrite()
            defer { if let lease {
                if exclusive { mutationGate?.endExclusiveWrite(lease) } else { mutationGate?.endWrite(lease) }
            } }
            return await commit(pending, to: store)
        } catch {
            self.error = pantryText("Pantry setup is in progress. Retry this change when it finishes.")
            return false
        }
    }

    @concurrent private static func encodeForSave(_ workspace: LedgerWorkspace) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LedgerDocument(formatVersion: 1, workspace: workspace))
    }

    private func verifyPantryBasis(_ basis: LedgerCanonicalPackStockEvidence.Basis) async throws {
        guard let port = pantryPackPort else { throw LedgerModelError.notReady }
        try requirePantryPackPort(port)
        try await port.assertCurrentLedgerBasis(basis)
    }

    private func commit(_ pending: PendingSave, to store: LedgerStore) async -> Bool {
        do {
            if pending.reviewedPantryBasis != nil || pending.authorize != nil {
                if pending.reviewedPantryBasis != nil {
                    guard let port = pantryPackPort, port.hasReadAccess else { throw LedgerModelError.notReady }
                    try requirePantryPackPort(port)
                }
                // The store validates an existing receipt's complete original
                // tuple. A new write still needs current action and food authority.
                if try await store.savedOperation(id: pending.operationID) == nil {
                    guard pending.authorize?() != false else { throw LedgerModelError.notReady }
                    if let basis = pending.reviewedPantryBasis { try await verifyPantryBasis(basis) }
                    guard pending.authorize?() != false else { throw LedgerModelError.notReady }
                }
                if pending.reviewedPantryBasis != nil, pantryPackPort?.hasReadAccess != true { throw LedgerModelError.notReady }
            }
            guard privatePantryWritable else { throw LedgerModelError.notReady }
            try AdultHomeSummaryStore.shared.invalidateLedger(store.workspaceID, forget: false)
            let record = try await store.save(payload: pending.payload, expectedRevision: pending.base,
                                              operationID: pending.operationID, savedAt: pending.savedAt, consuming: pending.firstListDraft)
            // No other mutation can start while saving, including during actor suspension.
            // Another store instance may have advanced after this operation's receipt.
            let current = try await store.load() ?? record
            if pending.reviewedPantryBasis != nil, pantryPackPort?.hasReadAccess != true {
                clearRetiredState()
                throw LedgerModelError.notReady
            }
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
            if let id = recovered.selectedShopID, id == pending.workspace.selectedShopID {
                pending.onShopSelected?(id)
            }
            return true
        } catch LedgerStoreError.erased {
            clearRetiredState()
            await open()
            self.error = recordsText("This ledger was deleted. Unsaved edits from its old workspace were discarded.")
            return false
        } catch LedgerStoreError.operationConflict where pending.firstListDraft != nil {
            self.pending = nil
            hasPendingSave = false
            error = ledgerText("This draft changed or expired. Reopen it to review the saved version.")
            return false
        } catch LedgerStoreError.staleRevision(expected: _, actual: _) {
            self.error = ledgerText("A newer pickup is saved. Discard the pending save to reload it, then review your entries again.")
            return false
        } catch {
            if pending.reviewedPantryBasis != nil, pantryPackPort?.hasReadAccess == false { clearRetiredState() }
            self.error = ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
            return false
        }
    }

    /// Composition installs this before editable state. The same instance is
    /// retained for retries; generic ledger saves never submit a pack request.
    func configurePantryPackRecovery(_ port: PantryPackSelectionCommitPort) async throws {
        guard ready, !saving, !opening, !hasPendingLedgerDeletion, !hasPendingPantryProjection,
              pending == nil else { throw LedgerModelError.notReady }
        try requirePantryPackPort(port)
        guard pantryPackPort == nil || pantryPackPort === port else { throw LedgerModelError.pendingChange }
        pantryPackPort = port
        saving = true; defer { saving = false }
        do {
            pendingPantryPack = try pendingPantryPack ?? port.readPending()
            hasPendingSave = pendingPantryPack != nil
            try adoptPantryPack(try await port.recover(pendingPantryPack), using: port)
        } catch { pantryPackFailed(error); throw error }
    }

    @discardableResult
    func savePantryPack(_ request: PantryPackSelectionCommitPort.Request,
                       using port: PantryPackSelectionCommitPort) async throws -> Bool {
        guard ready, !saving, !opening, !hasPendingLedgerDeletion, !hasPendingPantryProjection,
              pending == nil else { throw LedgerModelError.notReady }
        try requirePantryPackPort(port)
        guard pantryPackPort == nil || pantryPackPort === port else { throw LedgerModelError.pendingChange }
        pantryPackPort = port
        if let pendingPantryPack, pendingPantryPack.request != request { throw LedgerPackError.operationConflict }
        saving = true; defer { saving = false }
        do {
            switch try await port.prepare(request) {
            case .completed(let result):
                try adoptPantryPack(.committed(nil, result), using: port)
            case .pending(let entry):
                pendingPantryPack = entry; hasPendingSave = true
                try adoptPantryPack(try await port.recover(entry, commitIfUnapplied: true), using: port)
            }
            return pendingPantryPack == nil
        } catch {
            // Staging can reach disk before an attribute/transport failure.
            // Keep its exact original bytes available; never generate a new ID.
            if let retained = try? port.readPending() { pendingPantryPack = retained; hasPendingSave = true }
            pantryPackFailed(error)
            throw error
        }
    }

    private func requirePantryPackPort(_ port: PantryPackSelectionCommitPort) throws {
        guard sourceWorkspaceID == port.ledgerWorkspaceID,
              let mutationGate, port.matchesGate(mutationGate) else { throw LedgerModelError.notReady }
    }

    @discardableResult
    private func recoverPantryPack(commitIfUnapplied: Bool = false, discardIfUnapplied: Bool = false) async -> Bool {
        guard !saving, !opening, !hasPendingLedgerDeletion, !hasPendingPantryProjection,
              pending == nil, let port = pantryPackPort, let entry = pendingPantryPack else { return false }
        saving = true; defer { saving = false }
        do {
            try requirePantryPackPort(port)
            try adoptPantryPack(try await port.recover(entry, commitIfUnapplied: commitIfUnapplied,
                discardIfUnapplied: discardIfUnapplied), using: port)
            ready = true
            return pendingPantryPack == nil
        } catch { pantryPackFailed(error); return false }
    }

    private func adoptPantryPack(_ recovery: PantryPackSelectionCommitPort.PendingRecovery,
                                using port: PantryPackSelectionCommitPort) throws {
        guard port.hasReadAccess else { throw PantryPackSelectionCommitPort.Failure.unauthorized }
        switch recovery {
        case .waiting(let entry, let current):
            workspace = current.workspace; committedPayload = current.record?.payload
            revision = current.record?.revision ?? 0; savedAt = current.record?.savedAt
            pendingPantryPack = entry; hasPendingSave = true; pantryPackWasCommitted = false
            error = ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
        case .cleared(let current):
            workspace = current.workspace; committedPayload = current.record?.payload
            revision = current.record?.revision ?? 0; savedAt = current.record?.savedAt
            pendingPantryPack = nil; hasPendingSave = false; pantryPackWasCommitted = false; error = nil
        case .committed(let entry, let result):
            workspace = result.workspace; committedPayload = result.current.payload
            revision = result.current.revision; savedAt = result.current.savedAt
            pantryPackWasCommitted = true
            if let entry {
                pendingPantryPack = entry; hasPendingSave = true
                _ = try port.finishAdoption(entry, result: result)
            }
            pendingPantryPack = nil; hasPendingSave = false; pantryPackWasCommitted = false; error = nil
        }
    }

    private func pantryPackFailed(_ failure: Error) {
        if pantryPackPort?.hasReadAccess == false || failure as? PantryPackSelectionCommitPort.Failure == .unauthorized
            || failure as? LedgerStoreError == .erased {
            workspace = LedgerWorkspace(); committedPayload = nil; savedAt = nil; revision = 0; ready = false
            pendingPantryPack = nil; hasPendingSave = false
            pantryPackWasCommitted = false
        }
        error = pantryPackWasCommitted ? pantryText("Your change is saved. Retry to finish recovery.")
            : ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
    }

    /// The inventory binding is durable. Recovery never needs an obsolete ledger payload.
    func recoverPreparedProjection(_ source: PantryLedgerProjectionPort.Source,
                                   using port: PantryLedgerProjectionPort) async throws -> PantryLedgerProjectionPort.Result? {
        try await performPreparedProjection(source, payload: nil, using: port)
    }

    @discardableResult
    func applyPreparedProjection(_ source: PantryLedgerProjectionPort.Source, payload: Data,
                                 using port: PantryLedgerProjectionPort) async throws -> PantryLedgerProjectionPort.Result {
        guard let result = try await performPreparedProjection(source, payload: payload, using: port) else { throw LedgerModelError.notReady }
        return result
    }

    private func performPreparedProjection(_ source: PantryLedgerProjectionPort.Source, payload: Data?,
                                           using port: PantryLedgerProjectionPort) async throws -> PantryLedgerProjectionPort.Result? {
        guard inventoryProjectionsEnabled, ready, !saving, !opening, !hasPendingLedgerDeletion,
              pending == nil, pendingPantryPack == nil, sourceWorkspaceID == port.ledgerWorkspaceID else { throw LedgerModelError.notReady }
        guard pendingPantryProjection == nil || pendingPantryProjection?.source == source else { throw LedgerModelError.pendingChange }
        saving = true; defer { saving = false }
        do {
            if pendingPantryProjection == nil {
                pendingPantryProjection = try await port.preflight(source)
                hasPendingPantryProjection = true
            }
            let result: PantryLedgerProjectionPort.Result?
            if let payload { result = try await port.apply(source, payload: payload) }
            else { result = try await port.recover(source) }
            guard let result else {
                error = pantryText("Food is saved. Its plan update still needs review.")
                return nil
            }
            guard result.current.workspaceID == sourceWorkspaceID else { throw LedgerModelError.notReady }
            workspace = result.workspace; committedPayload = result.current.payload
            revision = result.current.revision; savedAt = result.current.savedAt
            pendingPantryProjection = nil; hasPendingPantryProjection = false; error = nil
            return result
        } catch LedgerStoreError.erased where pendingPantryProjection == nil {
            clearRetiredState()
            await open()
            throw LedgerStoreError.erased
        } catch {
            if hasPendingPantryProjection {
                self.error = pantryText("Food is saved. Retry the same plan update or review its current status.")
            }
            throw error
        }
    }

    /// Only an explicit review action may disposition unrecognized work; errors retain the validated pending source.
    @discardableResult
    func reconcilePreparedProjection(using port: PantryLedgerProjectionPort) async throws -> PantryLedgerProjectionPort.Reconciliation {
        guard !saving, !opening, !hasPendingLedgerDeletion, let pendingPantryProjection,
              sourceWorkspaceID == port.ledgerWorkspaceID else { throw LedgerModelError.notReady }
        saving = true; defer { saving = false }
        let result = try await port.reconcile(pendingPantryProjection)
        switch result {
        case let .applied(applied):
            workspace = applied.workspace; committedPayload = applied.current.payload
            revision = applied.current.revision; savedAt = applied.current.savedAt
            error = nil
        case let .needsReview(current):
            workspace = current.workspace; committedPayload = current.record?.payload
            revision = current.record?.revision ?? 0; savedAt = current.record?.savedAt
            error = pantryText("Food is saved. Its plan update still needs review.")
        case let .sourceRetired(current):
            workspace = current.workspace; committedPayload = current.record?.payload
            revision = current.record?.revision ?? 0; savedAt = current.record?.savedAt
            error = nil
        case .ledgerRetired:
            clearRetiredState()
        }
        self.pendingPantryProjection = nil; hasPendingPantryProjection = false
        if case .ledgerRetired = result { await open() }
        return result
    }

    /// Reload first, because an I/O interruption may hide a successful commit.
    func discardPendingSave() async {
        if pendingPantryPack != nil { _ = await recoverPantryPack(discardIfUnapplied: true); return }
        guard !saving, !hasPendingLedgerDeletion, !hasPendingPantryProjection, let store else { return }
        saving = true
        defer { saving = false }
        do {
            let lease = try mutationGate?.beginWrite()
            defer { if let lease { mutationGate?.endWrite(lease) } }
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
        guard try !usesLivePantry || privatePantryDeletionCheck?() == true else { throw LedgerDeletionError.pendingSave }
        guard pending == nil, pendingPantryPack == nil, !hasPendingPantryProjection else { throw LedgerDeletionError.pendingSave }
        guard ready, !saving, !opening, pending == nil, let store else { throw LedgerDeletionError.unavailable }
        let basis = try await store.workspaceErasureBasis()
        let source = try basis.head.map { try Self.validatePayload($0.payload) } ?? LedgerWorkspace()
        return WholeLedgerDeletionReview(workspaceID: store.workspaceID, revision: basis.head?.revision ?? 0,
            shopCount: source.shops.count, reusableDinnerCount: Set(source.mealTemplates.map(\.id) + source.dinnerPlanning.acceptedDinners.map { $0.template.id }).count,
            draftTokens: basis.draftTokens)
    }
    func retiredLedgerWorkspaceIDs() async throws -> [UUID] {
        guard let store else { throw LedgerDeletionError.unavailable }
        return try await store.retiredWorkspaceIDs()
    }
    @discardableResult
    func eraseWholeLedger(_ review: WholeLedgerDeletionReview) async throws -> LedgerWorkspaceTombstone {
        guard !hasPendingPantryProjection, pendingPantryPack == nil else { throw LedgerDeletionError.pendingSave }
        let lease = try mutationGate?.beginWrite()
        defer { if let lease { mutationGate?.endWrite(lease) } }
        if pendingLedgerDeletion != nil { return try await retryWholeLedgerDeletion() }
        guard try !usesLivePantry || privatePantryDeletionCheck?() == true else { throw LedgerDeletionError.pendingSave }
        guard ready, !saving, !opening, pending == nil, let journal = deletionJournalURL else { throw LedgerDeletionError.unavailable }
        let intent = LedgerDeletionIntent(formatVersion: 2, review: review, operationID: UUID(), requestedAt: clock())
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
        guard !hasPendingPantryProjection, pendingPantryPack == nil else { throw LedgerDeletionError.pendingSave }
        let lease = try mutationGate?.beginWrite()
        defer { if let lease { mutationGate?.endWrite(lease) } }
        guard !saving, !opening, let intent = pendingLedgerDeletion,
              let url = resolvedDatabaseURL, let journal = deletionJournalURL else { throw LedgerDeletionError.unavailable }
        saving = true; defer { saving = false }
        do {
            // Reopen even after an uncertain result: the old actor may be retired.
            let current = try LedgerStore(url: url, inventoryProjectionsEnabled: inventoryProjectionsEnabled)
            let receipt = try await current.eraseWorkspace(workspaceID: intent.review.workspaceID,
                expectedRevision: intent.review.revision, expectedDraftTokens: intent.review.draftTokens ?? [],
                operationID: intent.operationID, at: intent.requestedAt)
            try await current.close()
            clearRetiredState()
            let replacement = try LedgerStore(url: url, inventoryProjectionsEnabled: inventoryProjectionsEnabled)
            suspendPrivatePantryBinding()
            store = replacement; sourceWorkspaceID = replacement.workspaceID
            error = nil
            // Keep the journal until Records confirms erasure markers and orphan cleanup.
            return receipt
        } catch LedgerStoreError.erased {
            // Another authorized local instance may already have retired this source.
            // Reconcile its receipt without ever applying deletion to the replacement.
            let current = try LedgerStore(url: url, inventoryProjectionsEnabled: inventoryProjectionsEnabled)
            guard let receipt = try await current.tombstones().first(where: {
                $0.workspaceID == intent.review.workspaceID && $0.erasedRevision >= intent.review.revision
            }) else { throw LedgerDeletionError.invalidIntent }
            suspendPrivatePantryBinding()
            store = current; sourceWorkspaceID = current.workspaceID
            clearRetiredState()
            return receipt
        } catch LedgerStoreError.staleRevision, LedgerStoreError.staleFirstListDrafts {
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
        let lease = try mutationGate?.beginWrite()
        defer { if let lease { mutationGate?.endWrite(lease) } }
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
        pendingPantryPack = nil; pantryPackWasCommitted = false
        pending = nil; hasPendingSave = false; ready = false; search = ""
    }

    var firstListStore: LedgerStore? {
        guard privatePantryWritable, ready, !hasPendingLedgerDeletion else { return nil }
        return store
    }

    func commitFirstList(_ preview: StagedListImport, decisions: [UUID: ImportResolution], draft: FirstListDraftVersion,
                         title: String, authorize: @escaping @MainActor () -> Bool) async -> Bool {
        await change(key: "first-list-\(preview.id)", onShopSelected: nil, firstListDraft: draft, authorize: authorize) { candidate in
            guard !candidate.shops.contains(where: { $0.id == preview.shopID }), sourceWorkspaceID == draft.workspaceID, revision == draft.baseRevision,
                  preview.lines.contains(where: { decisions[$0.id] != nil && decisions[$0.id] != .skip }) else { throw LedgerError.stalePreview }
            var shop = ShoppingLedger(id: preview.shopID, title: title)
            try shop.commitImport(preview, decisions: decisions)
            candidate.shops.append(shop)
            candidate.selectedShopID = shop.id
        }
    }

    func addQuickGrocery(_ preview: StagedListImport, selectedShopID: UUID?, workspaceID: UUID,
                         authorize: @escaping @MainActor () -> Bool) async -> Bool {
        await change(key: "quick-grocery-\(preview.id)", onShopSelected: nil, authorize: authorize) { candidate in
            guard sourceWorkspaceID == workspaceID else { throw LedgerError.stalePreview }
            if candidate.selectedShopID == preview.shopID,
               let index = candidate.shops.firstIndex(where: { $0.id == preview.shopID }),
               candidate.shops[index].importBatches.contains(where: { $0.id == preview.id }) {
                try candidate.shops[index].commitImport(preview)
                return
            }
            guard candidate.selectedShopID == selectedShopID else { throw LedgerError.stalePreview }
            if let selectedShopID {
                guard selectedShopID == preview.shopID,
                      let index = candidate.shops.firstIndex(where: { $0.id == selectedShopID }) else {
                    throw LedgerError.stalePreview
                }
                try candidate.shops[index].commitImport(preview)
            } else {
                guard candidate.shops.isEmpty else { throw LedgerError.stalePreview }
                var shop = ShoppingLedger(id: preview.shopID, title: ledgerText("Pickup"))
                try shop.commitImport(preview)
                candidate.shops.append(shop)
                candidate.selectedShopID = shop.id
            }
        }
    }

    func startShop(title: String, onSelected: ((UUID) -> Void)? = nil) async -> Bool {
        await change(key: "start-shop", onShopSelected: onSelected) { workspace in
            let shop = ShoppingLedger(title: title)
            workspace.shops.append(shop)
            workspace.selectedShopID = shop.id
        }
    }

    func selectShop(_ id: UUID, onSelected: ((UUID) -> Void)? = nil) async {
        _ = await change(key: "select-\(id)", onShopSelected: onSelected) { $0.selectedShopID = id }
    }
}
