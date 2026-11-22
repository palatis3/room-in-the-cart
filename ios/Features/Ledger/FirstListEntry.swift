import CryptoKit
import Foundation
import SwiftUI
import CoreDomain
import LocalStore

struct FirstListContents: Equatable, Codable {
    var shopID = UUID()
    var importID = UUID()
    var original = ""
    var source: ImportSource = .typed
    var preview: StagedListImport?
    var choices: [UUID: ImportResolution] = [:]
    var invalidAmounts: [UUID: InvalidImportAmount] = [:]
    var explicitSeparate: Set<UUID> = []
    var matchesAreCurrent = true

    func appending(_ wording: String, pantryFood: Bool, shop: ShoppingLedger, pantrySuggestedAmount: Quantity? = nil, pantryProductLink: UUID? = nil) throws -> Self {
        guard shop.id == shopID else { throw LedgerError.stalePreview }
        let combinedWording = [original, wording].filter { !$0.isEmpty }.joined(separator: "\n")
        try StagedListImport.validateSourceText(combinedWording, maximumLines: StagedListImport.maximumLines)
        let before = try preview ?? shop.stageImport(text: original, source: source, importID: importID, reviewPackageCounts: true)
        guard before.id == importID, before.originalText == original else { throw LedgerError.stalePreview }
        let addition = try pantryFood
            ? PantryRestockReview.stage(food: wording, text: wording, source: .typed, id: UUID(), shop: shop, suggestedAmount: pantrySuggestedAmount, productLink: pantryProductLink)
            : shop.stageImport(text: wording, reviewPackageCounts: true)
        let combined = try shop.appendingImport(addition, to: before)
        var next = self
        next.original = combined.originalText
        next.preview = combined
        if preview == nil { next.choices = LedgerImportReview.initialChoices(before) }
        for row in combined.lines.dropFirst(before.lines.count) where row.duplicateLineIDs.isEmpty {
            next.choices[row.id] = .addNew
        }
        guard try JSONEncoder().encode(next).count <= LedgerStore.maximumFirstListDraftBytes else { throw LedgerStoreError.payloadTooLarge }
        return next
    }

}

/// One editor serializes its replacements. Other editors must still match SQLite's token.
@MainActor final class FirstListEditor: ObservableObject {
    let store: LedgerStore
    let owner: Data
    let base: Int64
    let authorize: @MainActor () -> Bool
    private(set) var version: FirstListDraftVersion?
    private(set) var content: FirstListContents
    private var saved: FirstListContents?
    private var writer: Task<Void, Never>?
    private var closed = false
    @Published private(set) var writing = false
    @Published private(set) var failed = false
    @Published private(set) var stale: Bool

    init(store: LedgerStore, owner: Data, base: Int64, saved: StoredFirstListDraft?, authorize: @escaping @MainActor () -> Bool) throws {
        self.store = store; self.owner = owner; self.base = base; self.authorize = authorize
        version = saved?.version
        if let saved { content = try JSONDecoder().decode(FirstListContents.self, from: saved.payload); self.saved = content }
        else { content = FirstListContents() }
        stale = saved.map { $0.version.baseRevision != base } ?? false
    }

    func update(_ next: FirstListContents) {
        guard !closed, authorize(), !stale else { return }
        content = next
        guard writer == nil else { return }
        if failed { failed = false }
        guard saved != content else { return }
        writing = true
        writer = Task {
            defer { writer = nil; writing = false }
            do {
                while !closed, authorize(), saved != content {
                    let value = content
                    guard value.original.utf8.count <= StagedListImport.maximumTextBytes else { throw LedgerStoreError.payloadTooLarge }
                    let bytes = try JSONEncoder().encode(value)
                    version = try await store.replaceFirstListDraft(owner: owner, expected: version, baseRevision: base, payload: bytes)
                    saved = value
                }
            } catch { failed = true }
        }
    }

    func flush(_ next: FirstListContents) async -> FirstListDraftVersion? {
        update(next)
        await writer?.value
        guard !closed, authorize(), saved == next, !failed, !stale else { return nil }
        return version
    }

    func closeSavingEdits(_ next: FirstListContents, prefill: String) async -> Bool {
        // A Shortcut initially displays transient wording. Closing that initial
        // screen is not an edit, but a pending write or failed edit still needs flushing.
        if version == nil, writer == nil, !failed {
            var untouched = content
            untouched.original = prefill
            if next == untouched { return true }
        }
        return await flush(next) != nil
    }

    func reviewAgain() async {
        guard stale, authorize() else { return }
        var current = FirstListContents()
        current.original = content.original
        stale = false
        if await flush(current) == nil { stale = true }
    }

    func discard() async -> Bool {
        guard !closed, authorize() else { return false }
        closed = true
        await writer?.value
        guard authorize() else { closed = false; return false }
        do {
            if let version { try await store.discardFirstListDraft(version) }
            return true
        } catch { closed = false; failed = true; return false }
    }
}

func firstListOwner(_ identity: CapturePrivateIdentity) throws -> Data {
    let fields: [String?] = [identity.actorID.uuidString, identity.subject, identity.householdID, identity.memberID, identity.role]
    return Data(SHA256.hash(data: try JSONEncoder().encode(fields)))
}

struct FirstListResumeButton: View {
    @ObservedObject var model: LedgerModel
    let showingEditor: Bool
    let open: () -> Void
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @State private var found: Query?

    private var owner: Data? {
        guard child?.presented != true, household.projection?.grantId == nil,
              let identity = CapturePrivateIdentity.current(access: access, household: household) else { return nil }
        return try? firstListOwner(identity)
    }
    private struct Query: Equatable { let owner: Data?; let workspace: UUID?; let revision: Int64; let showingEditor: Bool }
    var body: some View {
        let query = Query(owner: owner, workspace: model.sourceWorkspaceID, revision: model.revision, showingEditor: showingEditor)
        Group {
            if query.owner != nil, found == query {
                Button(ledgerText("Resume list draft"), action: open).frame(minHeight: 44)
                    .accessibilityIdentifier("shop.resumeFirstList")
            }
        }.task(id: query) {
            found = nil
            guard let owner = query.owner, let store = model.firstListStore else { return }
            if (try? await store.firstListDraft(owner: owner)) != nil, !Task.isCancelled { found = query }
        }
    }
}

struct FirstListEntry: View {
    @ObservedObject var model: LedgerModel
    var prefill: String = ""
    var opensListAfterSave = false
    var pantryFoodPrefill = false
    var pantrySuggestedAmount: Quantity? = nil
    var pantryProductLink: UUID? = nil
    var authorizeEntry: @MainActor () -> Bool = { true }
    let onSaved: (UUID) -> Void
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.dismiss) private var dismiss
    @State private var editor: FirstListEditor?
    @State private var failed = false

    private var identity: CapturePrivateIdentity? {
        guard child?.presented != true, household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var committedHere: Bool {
        guard let editor, editor.store === model.firstListStore, let identity,
              (try? firstListOwner(identity)) == editor.owner,
              let preview = editor.content.preview, let shop = model.shop, shop.id == preview.shopID else { return false }
        return shop.importBatches.contains { $0.id == preview.id && $0.undoneAt == nil }
    }

    var body: some View {
        Group {
            if let editor, editor.authorize() {
                FirstListForm(model: model, editor: editor, prefill: prefill, opensListAfterSave: opensListAfterSave, pantryFoodPrefill: pantryFoodPrefill, pantrySuggestedAmount: pantrySuggestedAmount, pantryProductLink: pantryProductLink, onSaved: onSaved)
            } else if committedHere {
                // Committing our own batch advanced the revision before its sheet finished closing.
                ProgressView()
            } else if failed || identity == nil || editor != nil {
                ContentUnavailableView(ledgerText("Draft unavailable"), systemImage: "lock",
                    description: Text(ledgerText("Reopen the private shopping list to check the current workspace.")))
            } else { ProgressView() }
        }
        .toolbar {
            if !committedHere, failed || identity == nil || editor?.authorize() == false {
                ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Close")) { dismiss() } }
            }
        }
        .task { await open() }
    }

    private func open() async {
        guard let store = model.firstListStore, let original = identity else { failed = true; return }
        let base = model.revision, child = child, access = access, household = household, model = model
        let authorize: @MainActor () -> Bool = { [weak model, weak access, weak household, weak child] in
            guard authorizeEntry(), let model, let access, let household, child?.presented != true,
                  household.projection?.grantId == nil, model.firstListStore === store,
                  model.revision == base, UIApplication.shared.isProtectedDataAvailable else { return false }
            return CapturePrivateIdentity.current(access: access, household: household) == original
        }
        do {
            let owner = try firstListOwner(original)
            guard authorize() else { failed = true; return }
            let saved = try await store.firstListDraft(owner: owner)
            guard authorize(), !Task.isCancelled, model.workspace.shops.isEmpty || saved != nil else { failed = true; return }
            editor = try FirstListEditor(store: store, owner: owner, base: base, saved: saved, authorize: authorize)
        } catch { failed = true }
    }
}

private struct FirstListForm: View {
    @ObservedObject var model: LedgerModel
    @ObservedObject var editor: FirstListEditor
    let prefill: String
    let opensListAfterSave: Bool
    let pantryFoodPrefill: Bool
    let pantrySuggestedAmount: Quantity?
    let pantryProductLink: UUID?
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if editor.stale {
            WorkingForm {
                Text(ledgerText("The shopping workspace changed. Review your draft wording again before creating a pickup."))
                Text(verbatim: editor.content.original)
                Button(ledgerText("Review as a new pickup")) { Task { await editor.reviewAgain() } }
                FirstListDiscardButton(editor: editor, blocked: false)
            }.toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Close")) { dismiss() } } }
        } else {
            LedgerImportView(model: model, shopID: editor.content.shopID, firstDraft: editor, prefill: prefill, opensListAfterSave: opensListAfterSave, pantryFoodPrefill: pantryFoodPrefill, pantrySuggestedAmount: pantrySuggestedAmount, pantryProductLink: pantryProductLink, authorizeEntry: editor.authorize, onSaved: onSaved)
        }
    }
}


struct FirstListDraftStatus: View {
    @ObservedObject var editor: FirstListEditor
    let contents: FirstListContents
    let blocked: Bool
    @Environment(\.dismiss) private var dismiss

    private var message: String {
        if editor.failed { return ledgerText("Draft could not be saved. Keep this screen open or reopen the saved version.") }
        if editor.writing { return ledgerText("Saving draft on this device…") }
        if editor.version != nil { return ledgerText("Private draft saved on this device. It expires 7 days after your last edit.") }
        return ledgerText("A private draft expires 7 days after your last edit.")
    }

    var body: some View {
        Section {
            Text(message).accessibilityIdentifier("firstList.draftStatus")
            if editor.failed {
                Button(ledgerText("Retry saving draft")) { editor.update(contents) }
                Button(ledgerText("Close without saving these changes")) { dismiss() }
            }
            if editor.version != nil || !contents.original.isEmpty {
                FirstListDiscardButton(editor: editor, blocked: blocked)
            }
        }
    }
}

private struct FirstListDiscardButton: View {
    @ObservedObject var editor: FirstListEditor
    let blocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        Button(ledgerText("Discard draft"), role: .destructive) { confirming = true }
            .disabled(blocked)
            .accessibilityIdentifier("firstList.discard")
            .confirmationDialog(ledgerText("Discard this shopping list draft?"), isPresented: $confirming, titleVisibility: .visible) {
                Button(ledgerText("Discard draft"), role: .destructive) {
                    Task { if !blocked, await editor.discard() { dismiss() } }
                }
                Button(ledgerText("Keep editing"), role: .cancel) {}
            }
    }
}
