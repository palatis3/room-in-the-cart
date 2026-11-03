import Foundation
import Combine
import CoreDomain
import LocalStore

private struct LedgerDocument: Codable {
    let formatVersion: Int
    let workspace: LedgerWorkspace
}

private enum LedgerModelError: Error { case unsupportedDocument, noShop, notReady, pendingChange }

/// UI drafts remain in their sheets. A candidate becomes visible only after the
/// store commits it; the receipt's exact bytes and operation ID survive retries.
@MainActor final class LedgerModel: ObservableObject {
    @Published private(set) var workspace = LedgerWorkspace()
    @Published private(set) var savedAt: Date?
    @Published private(set) var saving = false
    @Published private(set) var opening = false
    @Published private(set) var ready = false
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var sourceWorkspaceID: UUID?
    @Published private(set) var hasPendingSave = false
    @Published var error: String?
    @Published var search = ""
    private let databaseURL: URL?
    private let clock: () -> Date
    private var store: LedgerStore?
    private var committedPayload: Data?
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
        guard ready else { throw LedgerModelError.notReady }
        try workspace.validate()
        if let committedPayload { return committedPayload }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LedgerDocument(formatVersion: 1, workspace: workspace))
    }

    nonisolated static func validatePayload(_ payload: Data) throws -> LedgerWorkspace {
        guard payload.count <= 4 * 1_024 * 1_024 else { throw LedgerModelError.unsupportedDocument }
        let document = try JSONDecoder().decode(LedgerDocument.self, from: payload)
        guard document.formatVersion == 1 else { throw LedgerModelError.unsupportedDocument }
        try document.workspace.validate()
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
            if ProcessInfo.processInfo.arguments.contains("--reset-test-workspace"), directory.lastPathComponent == "UITestWorkspace" {
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: url.path + suffix)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            }
            #endif
            let opened = try LedgerStore(url: url)
            if let record = try await opened.load() {
                let document = try JSONDecoder().decode(LedgerDocument.self, from: record.payload)
                guard document.formatVersion == 1 else { throw LedgerModelError.unsupportedDocument }
                try document.workspace.validate()
                workspace = document.workspace
                committedPayload = record.payload
                revision = record.revision
                savedAt = record.savedAt
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
        guard !saving, ready else { return false }
        if pending != nil {
            error = ledgerText("Retry or discard the unsaved change before making another change.")
            return false
        }
        do {
            var candidate = workspace
            try edit(&candidate)
            try candidate.validate()
            guard candidate != workspace else { error = nil; return true }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(LedgerDocument(formatVersion: 1, workspace: candidate))
            pending = PendingSave(key: key, workspace: candidate, payload: payload, base: revision,
                                  operationID: UUID(), savedAt: clock())
            hasPendingSave = true
            return await retrySave()
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

    @discardableResult
    func editShop(key: String, shopID: UUID, _ edit: (inout ShoppingLedger) throws -> Void) async -> Bool {
        await change(key: key) { workspace in
            guard let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw LedgerModelError.noShop }
            try edit(&workspace.shops[index])
        }
    }

    @discardableResult
    func retrySave() async -> Bool {
        guard !saving, let pending, let store else { return false }
        saving = true
        defer { saving = false }
        do {
            let record = try await store.save(payload: pending.payload, expectedRevision: pending.base,
                                              operationID: pending.operationID, savedAt: pending.savedAt)
            // No other mutation can start while saving, including during actor suspension.
            // Another store instance may have advanced after this operation's receipt.
            let current = try await store.load() ?? record
            let document = try JSONDecoder().decode(LedgerDocument.self, from: current.payload)
            guard document.formatVersion == 1 else { throw LedgerModelError.unsupportedDocument }
            try document.workspace.validate()
            workspace = document.workspace
            committedPayload = current.payload
            revision = current.revision
            savedAt = current.savedAt
            self.pending = nil
            hasPendingSave = false
            error = nil
            return true
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
        guard !saving, let store else { return }
        saving = true
        defer { saving = false }
        do {
            if let record = try await store.load() {
                let document = try JSONDecoder().decode(LedgerDocument.self, from: record.payload)
                guard document.formatVersion == 1 else { throw LedgerModelError.unsupportedDocument }
                try document.workspace.validate()
                workspace = document.workspace
                committedPayload = record.payload
                revision = record.revision
                savedAt = record.savedAt
            }
            pending = nil
            hasPendingSave = false
            error = nil
        } catch { self.error = ledgerText("Could not reload the saved pickup. Your pending change is still available to retry.") }
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
