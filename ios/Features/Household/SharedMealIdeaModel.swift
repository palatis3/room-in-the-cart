import Foundation
import Combine
import HouseholdClient

protocol SharedMealIdeasServing: Sendable {
    func sharedMealIdeas(shopID: UUID) async throws -> SharedMealIdeaPage
    func writeSharedMealIdea(shopID: UUID, request: SharedMealIdeaWrite) async throws -> SharedMealIdeaReceipt
}
extension HouseholdService: SharedMealIdeasServing {}

@MainActor final class SharedMealIdeaModel: ObservableObject {
    let scope: SharedMealChangeScope
    private let service: any SharedMealIdeasServing
    private let runtime: () -> SharedMealChangeScope?
    private var generation = UUID()
    @Published private(set) var page: SharedMealIdeaPage?
    @Published private(set) var pending: SharedMealIdeaWrite?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var savedID: UUID?
    init(scope: SharedMealChangeScope, service: any SharedMealIdeasServing, runtime: @escaping () -> SharedMealChangeScope?) {
        self.scope = scope; self.service = service; self.runtime = runtime
    }
    var live: Bool { runtime() == scope }
    func invalidate() { generation = UUID(); page = nil; pending = nil; busy = false; notice = nil; savedID = nil }
    private func current(_ value: UUID) -> Bool { live && generation == value }
    func load() async {
        guard live, !busy else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            let value = try await service.sharedMealIdeas(shopID: scope.shopID)
            guard current(start) else { return }; page = value
        } catch { fail(start) }
    }
    func write(ideaID: UUID, draft: SharedMealIdeaDraft, approve: Bool, reviewed: Bool) async {
        guard live, !busy, pending == nil, let page else { return }
        let draft = draft.normalizedForSave()
        let original = page.ideas.first { $0.id == ideaID }
        guard original == nil || original?.actorId.uuidString.lowercased() == scope.memberID.lowercased() else { return }
        guard !approve || (reviewed && original?.draft == draft && original?.preview.canApprove == true) else { return }
        do { try draft.validate() } catch { notice = ht("Enter a meal name, ingredient names, and household evidence. Quantities may stay unknown while drafting."); return }
        pending = .init(ideaId: ideaID, baseRevision: original?.revision, page: page, action: approve ? "approve" : "save", draft: draft, reviewedHouseholdEvidence: reviewed)
        await retry()
    }
    func retry() async {
        guard live, !busy, let pending else { return }
        let start = generation; busy = true; notice = nil
        defer { if current(start) { busy = false } }
        do {
            let receipt = try await service.writeSharedMealIdea(shopID: scope.shopID, request: pending)
            guard current(start), receipt.saved, receipt.ideaId == pending.ideaId else { return }
            self.pending = nil; savedID = receipt.ideaId
            notice = ht("Idea saved in this household. Approval and a proposal are separate; no meal or pack was changed.")
            let latest = try await service.sharedMealIdeas(shopID: scope.shopID)
            guard current(start) else { return }; page = latest
        } catch { fail(start) }
    }
    /// A fresh read lets the adult inspect any accepted write before explicitly abandoning local retry.
    func reconcile() async {
        await load()
        guard live, !busy, let page, let pending,
              let idea = page.ideas.first(where: { $0.id == pending.ideaId }), idea.draft == pending.draft,
              idea.revision == (pending.baseRevision ?? 0) + 1,
              idea.state == (pending.action == "approve" ? "approved" : "draft") else { return }
        self.pending = nil; savedID = idea.id
    }
    private func fail(_ start: UUID) {
        guard current(start) else { return }
        page = nil
        notice = ht("The household result is not confirmed. Refresh status or retry the exact saved idea after checking your access.")
    }
}
