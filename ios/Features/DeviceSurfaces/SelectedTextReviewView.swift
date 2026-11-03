import SwiftUI
import DeviceSurfaces

public struct CommittedSelectedTextImport: Sendable {
    public let operationID: UUID
    public let digest: String
    public init(operationID: UUID, digest: String) { self.operationID = operationID; self.digest = digest }
}

@MainActor public final class SelectedTextReviewModel: ObservableObject {
    @Published public private(set) var entries: [SelectedTextEntry] = []
    @Published public private(set) var busy = false
    @Published public private(set) var message: String?
    private let inbox: SelectedTextInbox
    /// Return a generation only for a currently unlocked, permitted private-inbox session.
    private let generation: () -> UUID?
    private let review: (SelectedTextEntry) async throws -> CommittedSelectedTextImport?
    public init(inbox: SelectedTextInbox, authorizedGeneration: @escaping () -> UUID?, review: @escaping (SelectedTextEntry) async throws -> CommittedSelectedTextImport?) {
        self.inbox = inbox; generation = authorizedGeneration; self.review = review
    }
    public func invalidateScope() { entries = []; message = nil }
    public func refresh() async {
        guard let start = generation() else { invalidateScope(); return }
        do { let rows = try await inbox.pending(now: Date()); guard generation() == start else { invalidateScope(); return }; entries = rows }
        catch { guard generation() == start else { return }; message = SurfaceCopy.text("Selected text could not be opened. Try again.") }
    }
    public func reviewEntry(_ entry: SelectedTextEntry) async {
        guard !busy, let start = generation() else { invalidateScope(); return }
        busy = true; defer { busy = false }
        do {
            guard let pending = try await inbox.pending(now: Date()).first(where: { $0.id == entry.id }), pending.receipt.digest == entry.receipt.digest,
                  generation() == start else { await refresh(); return }
            guard let committed = try await review(entry) else { return }
            guard generation() == start else { invalidateScope(); return }
            guard committed.operationID == entry.id, committed.digest == entry.receipt.digest else { throw SurfaceError.changedReplay }
            _ = try await inbox.acknowledgeCommitted(operationID: entry.id, digest: entry.receipt.digest, now: Date())
            await refresh()
        } catch { guard generation() == start else { return }; message = SurfaceCopy.text("Review could not finish. Reopen this entry to check its saved result.") }
    }
    public func discard(_ entry: SelectedTextEntry) async {
        guard !busy, let start = generation() else { invalidateScope(); return }
        busy = true; defer { busy = false }
        do { _ = try await inbox.discard(operationID: entry.id, digest: entry.receipt.digest, now: Date()); guard generation() == start else { invalidateScope(); return }; await refresh() }
        catch { guard generation() == start else { return }; message = SurfaceCopy.text("Selected text could not be removed. Try again.") }
    }
}

public struct SelectedTextReviewView: View {
    @ObservedObject private var model: SelectedTextReviewModel
    public init(model: SelectedTextReviewModel) { self.model = model }
    public var body: some View {
        List {
            Section { Text(SurfaceCopy.text("Selected text waits for your review. Nothing has been added to a shop.")) }
            ForEach(model.entries) { entry in
                Section {
                    Text(entry.originalText).textSelection(.enabled)
                    if let edited = entry.editedText { Text(edited) }
                    Text(entry.receipt.expiresAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                    Button(SurfaceCopy.text("Review selected text")) { Task { await model.reviewEntry(entry) } }.frame(minHeight: 44)
                    Button(SurfaceCopy.text("Discard selected text"), role: .destructive) { Task { await model.discard(entry) } }.frame(minHeight: 44)
                }.disabled(model.busy)
            }
            if let message = model.message { Text(message); Button(SurfaceCopy.text("Try again")) { Task { await model.refresh() } } }
        }.navigationTitle(SurfaceCopy.text("Selected text")).task { await model.refresh() }
    }
}
