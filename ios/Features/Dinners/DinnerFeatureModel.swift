import Foundation
import Combine
import CoreDomain

@MainActor protocol DinnerWorkspaceStore: AnyObject {
    var workspace: LedgerWorkspace { get }
    var sourceWorkspaceID: UUID? { get }
    var ready: Bool { get }
    var saving: Bool { get }
    var hasPendingSave: Bool { get }
    func change(key: String, _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool
}

/// No imported document can provide this feature's authority. The coordinator supplies
/// a fresh runtime binding for each preview, metadata save, and final Apply.
@MainActor final class DinnerFeatureModel: ObservableObject {
    typealias AccessProvider = (UUID) -> DinnerAccessContext?
    @Published private(set) var preview: DinnerPreview?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    let store: any DinnerWorkspaceStore
    let accessProvider: AccessProvider
    let phaseProvider: (UUID) -> BasketPhase
    let ideaCatalog: [MealTemplate]
    private let clock: () -> Date
    private var observation: AnyCancellable?
    private var runtimeObservation: AnyCancellable?

    init(store: any DinnerWorkspaceStore, access: @escaping AccessProvider,
         phase: @escaping (UUID) -> BasketPhase, ideaCatalog: [MealTemplate] = [],
         clock: @escaping () -> Date = Date.init) {
        self.store = store; accessProvider = access; phaseProvider = phase
        self.ideaCatalog = ideaCatalog; self.clock = clock
    }
    func observe(_ publisher: ObservableObjectPublisher) {
        observation = publisher.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func observeRuntime(_ publisher: AnyPublisher<Void, Never>) {
        runtimeObservation = publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var workspace: LedgerWorkspace { store.workspace }
    var shop: ShoppingLedger? { workspace.shops.first { $0.id == workspace.selectedShopID } }
    var state: DinnerPlanningState { workspace.dinnerPlanning }
    var editable: Bool { store.ready && !store.saving && !store.hasPendingSave && !busy }
    var paid: Bool { guard let shop else { return false }; return (try? access(for: shop.id).hasPaidTools) == true }
    var budgetVisible: Bool { guard let shop else { return false }; return (try? access(for: shop.id).canReadBudget) == true }
    var accessAvailable: Bool { guard let shop else { return false }; return (try? access(for: shop.id)) != nil }
    struct EditorIdentity: Equatable {
        let scope: DinnerAccessContext.Scope
        let actorID: String
        let shopID: UUID
    }
    var editorIdentity: EditorIdentity? {
        guard let shop, let context = try? access(for: shop.id) else { return nil }
        return EditorIdentity(scope: context.scope, actorID: context.actorID, shopID: shop.id)
    }
    var localIdeaWorkspaceID: UUID? {
        guard let shop, let context = try? access(for: shop.id), case .local(let workspaceID) = context.scope else { return nil }
        return workspaceID
    }
    var canReviewPreview: Bool {
        guard let preview, shop?.id == preview.proposal.shopID, let access = try? access(for: preview.proposal.shopID) else { return false }
        let namespace: String
        switch access.scope { case .local(let id): namespace = "local:\(id.uuidString)"; case .household(let id): namespace = "household:\(id)" }
        return namespace == preview.proposal.namespace && access.actorID == preview.proposal.authorID
    }
    var canApply: Bool {
        guard editable, canReviewPreview, let preview, !preview.needsPurchaseAmendment, !preview.proposal.isIsolatedPreview,
              let access = try? access(for: preview.proposal.shopID), case .local = access.scope,
              (try? access.validate(shopID: preview.proposal.shopID, at: clock(), applying: true)) != nil else { return false }
        return !preview.proposal.tool.requiresPaidAccess || access.hasPaidTools
    }
    var sharedPreview: Bool {
        guard let id = preview?.proposal.shopID, let access = try? access(for: id) else { return false }
        if case .household = access.scope { return true }; return false
    }
    private func access(for shopID: UUID) throws -> DinnerAccessContext {
        guard let access = accessProvider(shopID) else { throw DinnerPlanningError.forbidden }
        try access.validate(shopID: shopID, at: clock())
        if case .local(let id) = access.scope {
            guard id == store.sourceWorkspaceID else { throw DinnerPlanningError.forbidden }
        }
        return access
    }
    func week(start: MealDay) throws -> DinnerMealWeek {
        guard let shop else { throw DinnerPlanningError.invalid("shop") }
        return try DinnerPlanningEngine.week(start: start, ledger: shop, state: state,
            access: access(for: shop.id), at: clock())
    }
    @discardableResult func prepare(_ changes: [DinnerLedgerChange], tool: DinnerPlanningTool = .manual, isolated: Bool = false, expectedRevision: UUID? = nil) -> Bool {
        guard editable, let shop else { return false }
        do {
            if let expectedRevision, expectedRevision != shop.revisionID { throw DinnerPlanningError.stalePreview }
            preview = try DinnerPlanningEngine.preview(changes: changes, tool: tool, ledger: shop,
                state: state, access: access(for: shop.id), phase: phaseProvider(shop.id), at: clock(), isolated: isolated)
            error = nil; notice = nil; return true
        } catch { preview = nil; fail(error); return false }
    }
    func cancelPreview() { preview = nil; error = nil }
    func endDecision(restoring previous: DinnerPreview?) {
        cancelPreview()
        guard let previous, shop?.id == previous.proposal.shopID, shop?.revisionID == previous.proposal.baseRevisionID,
              state.revisionID == previous.proposal.planningRevisionID else { return }
        preview = previous
        if !canReviewPreview { preview = nil }
    }
    @discardableResult func applyPreview() async -> Bool {
        guard canApply, let reviewed = preview else { fail(DinnerPlanningError.forbidden); return false }
        let ok = await mutate(key: "dinner-apply-\(reviewed.proposal.id)", shopID: reviewed.proposal.shopID) { workspace, index, access, now in
            // The local adapter has no server commit binding. Even a caller-supplied
            // sharedCommitAuthorized bit cannot enable a shared authoritative write.
            guard case .local = access.scope else { throw DinnerPlanningError.forbidden }
            _ = try DinnerPlanningEngine.apply(reviewed.proposal, ledger: &workspace.shops[index],
                state: &workspace.dinnerPlanning, access: access, phase: self.phaseProvider(reviewed.proposal.shopID), at: now)
        }
        if ok { preview = nil; notice = dinnerText("Dinner changes saved.") }
        return ok
    }
    @discardableResult func savePreviewAsProposal() async -> Bool {
        guard canReviewPreview, let reviewed = preview, !reviewed.proposal.isIsolatedPreview else { return false }
        let ok = await mutate(key: "dinner-proposal-\(reviewed.proposal.id)", shopID: reviewed.proposal.shopID) { workspace, _, access, now in
            try workspace.dinnerPlanning.saveProposal(reviewed.proposal, access: access, at: now)
        }
        if ok { notice = dinnerText("Proposal saved on this device. It has not been sent or applied.") }
        return ok
    }
    @discardableResult func accept(_ template: MealTemplate, id: UUID, fallback: Bool) async -> Bool {
        guard let shop else { return false }
        return await mutate(key: "dinner-accept-\(id)", shopID: shop.id) { workspace, _, access, now in
            if let existing = workspace.dinnerPlanning.acceptedDinners.first(where: { $0.id == id }) {
                guard existing.template == template, existing.acceptedFallback == fallback else { throw DinnerPlanningError.operationConflict }
                return
            }
            try workspace.dinnerPlanning.accept(AcceptedDinner(id: id, template: template, acceptedAt: now, acceptedFallback: fallback), access: access, at: now)
        }
    }
    @discardableResult func choose(_ dinner: AcceptedDinner, day: MealDay?) -> Bool {
        prepare([.choose(PlannedDinner(acceptedDinnerID: dinner.id, template: dinner.template, day: day))], tool: .reusableDinner)
    }
    @discardableResult func selectFree(_ id: UUID) async -> Bool {
        guard let shop else { return false }
        return await mutate(key: "dinner-free-\(id)", shopID: shop.id) { workspace, _, access, now in
            try workspace.dinnerPlanning.selectFreeReusableDinner(id, access: access, at: now)
        }
    }
    @discardableResult func saveNote(_ note: DinnerWeekNote) async -> Bool {
        await mutate(key: "dinner-note-\(note.id)", shopID: note.shopID) { workspace, _, access, now in
            try workspace.dinnerPlanning.recordWeekNote(note, access: access, at: now)
        }
    }
    @discardableResult func saveRotation(_ rotation: DinnerRotation) async -> Bool {
        guard let shop else { return false }
        return await mutate(key: "dinner-rotation-\(rotation.id)-\(rotation.revision)", shopID: shop.id) { workspace, _, access, now in
            try workspace.dinnerPlanning.saveRotation(rotation, access: access, at: now)
        }
    }
    @discardableResult func previewRotation(_ rotation: DinnerRotation, selected: [UUID], start: MealDay) -> Bool {
        guard editable, let shop else { return false }
        do {
            // The engine's reusable rotation path enforces paid access. Free users
            // continue to choose and date individual dinners through manual tools.
            preview = try DinnerPlanningEngine.previewRotation(rotationID: rotation.id,
                selectedEntryIDs: selected, weekStart: start, ledger: shop, state: state,
                access: access(for: shop.id), phase: phaseProvider(shop.id), at: clock())
            error = nil; return true
        } catch { preview = nil; fail(error); return false }
    }
    @discardableResult func saveBindings(_ bindings: [DinnerPortionBinding], occurrenceID: UUID) async -> Bool {
        guard let shop else { return false }
        return await mutate(key: "dinner-bindings-\(occurrenceID)", shopID: shop.id) { workspace, index, access, now in
            try workspace.dinnerPlanning.setPortionBindings(bindings, for: occurrenceID, ledger: workspace.shops[index], access: access, at: now)
        }
    }
    @discardableResult func previewGuests(occurrenceID: UUID, servings: [UUID: Rational], isolated: Bool = false) -> Bool {
        guard editable, let shop else { return false }
        do {
            preview = try DinnerPlanningEngine.previewGuests(occurrenceID: occurrenceID, servingsByGroup: servings,
                ledger: shop, state: state, access: access(for: shop.id), phase: phaseProvider(shop.id), at: clock(), isolated: isolated)
            error = nil; return true
        } catch { preview = nil; fail(error); return false }
    }
    /// A structured voice review supplies a total for one explicitly selected group.
    /// Capturing speech does not change this model's persisted workspace.
    @discardableResult func previewGuestTotal(occurrenceID: UUID, groupID: UUID, total: Rational,
                                              reviewedRevision: UUID) -> Bool {
        guard editable, let shop else { return false }
        do {
            guard shop.revisionID == reviewedRevision else { throw DinnerPlanningError.stalePreview }
            guard let meal = shop.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }),
                  let group = meal.servingGroups.first(where: { $0.id == groupID }) else { throw DinnerPlanningError.notFound(groupID) }
            guard !group.isProtected, total > .zero else { throw DinnerPlanningError.reviewRequired("guestGroup") }
            var totals = Dictionary(uniqueKeysWithValues: meal.servingGroups.map { ($0.id, $0.servings) })
            totals[groupID] = total
            return previewGuests(occurrenceID: occurrenceID, servings: totals, isolated: !paid)
        } catch { preview = nil; fail(error); return false }
    }
    func newIdea(seed: UInt64, exclusions: [String], manual: MealTemplate? = nil) throws -> DinnerIdeaDraft {
        guard let shop else { throw DinnerPlanningError.invalid("shop") }
        _ = try access(for: shop.id)
        if let manual {
            return DinnerIdeaDraft(requestID: UUID(), catalogVersion: "manual-v1", template: manual,
                hardExclusions: exclusions, createdAt: clock())
        }
        var draft = try DinnerIdeaEngine.draft(requestID: UUID(), draftID: UUID(), catalogVersion: "reviewed-catalog-v1",
            catalog: ideaCatalog, seed: seed, householdExclusions: exclusions, at: clock())
        draft.assumptions = [dinnerText("Check which ingredients are available and how much usable food the recipe makes.")]
        return draft
    }
    @discardableResult func saveIdea(_ draft: DinnerIdeaDraft) async -> Bool {
        guard let shop else { return false }
        return await mutate(key: "dinner-idea-\(draft.id)", shopID: shop.id) { workspace, _, access, now in
            try workspace.dinnerPlanning.saveIdea(draft, access: access, at: now)
        }
    }
    @discardableResult func acceptIdea(_ draft: DinnerIdeaDraft, acceptedID: UUID) async -> Bool {
        guard let shop else { return false }
        let ok = await mutate(key: "dinner-idea-accept-\(draft.id)", shopID: shop.id) { workspace, _, access, now in
            _ = try workspace.dinnerPlanning.acceptIdea(draft, acceptedID: acceptedID, access: access, at: now)
        }
        if ok { notice = dinnerText("Idea accepted. Choose it separately to add grocery needs.") }
        return ok
    }
    /// Scenario inputs must come from an explicit ingredient/stock/pack review.
    /// No product-name inference or automatic current-basket replacement occurs here.
    func pair(current: DinnerScenario, alternatives: [DinnerScenario], selected: Set<UUID>,
              cap: CheckoutCap?, isolated: Bool = false) throws -> DinnerPairingResult {
        guard let shop else { throw DinnerPlanningError.invalid("shop") }
        return try DinnerScenarioEngine.pair(current: current, alternatives: alternatives,
            selectedAcceptedDinnerIDs: selected, state: state, cap: cap,
            access: access(for: shop.id), at: clock(), isolated: isolated, ledger: shop)
    }
    func recover(alternatives: [DinnerScenario], cap: CheckoutCap?, extraTripAccepted: Bool) throws -> DinnerRecoveryResult {
        guard let shop else { throw DinnerPlanningError.invalid("shop") }
        return try DinnerScenarioEngine.recover(alternatives: alternatives, state: state, cap: cap,
            access: access(for: shop.id), at: clock(), extraTripAccepted: extraTripAccepted, ledger: shop)
    }
    func compare(_ pair: TwoStoreQuotePair) throws -> TwoStoreQuoteResult {
        try TwoStoreQuoteEngine.compare(pair, access: access(for: pair.shopID), at: clock())
    }
    @discardableResult func saveQuotePair(_ pair: TwoStoreQuotePair) async -> Bool {
        await mutate(key: "dinner-quotes-\(pair.id)", shopID: pair.shopID) { workspace, index, access, now in
            guard pair.baseRevisionID == workspace.shops[index].revisionID,
                  pair.basisRevision == workspace.shops[index].basisRevision else { throw DinnerPlanningError.stalePreview }
            try workspace.dinnerPlanning.saveQuotePair(pair, access: access, at: now)
        }
    }
    @discardableResult func previewAdoption(_ pair: TwoStoreQuotePair, option: StoreQuoteOption) -> Bool {
        guard editable, let shop, let basis = option.adoptionBasis else { return false }
        do {
            preview = try TwoStoreQuoteEngine.previewAdoption(pair, optionID: option.id, basis: basis,
                ledger: shop, state: state, access: access(for: shop.id), phase: phaseProvider(shop.id), at: clock())
            error = nil; return true
        } catch { preview = nil; fail(error); return false }
    }
    private func mutate(key: String, shopID: UUID,
                        edit: (inout LedgerWorkspace, Int, DinnerAccessContext, Date) throws -> Void) async -> Bool {
        guard editable else { return false }
        busy = true; defer { busy = false }
        var failure: Error?
        let saved = await store.change(key: key) { workspace in
            do {
                let current = try self.access(for: shopID)
                guard let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw DinnerPlanningError.notFound(shopID) }
                try edit(&workspace, index, current, self.clock())
            } catch { failure = error; throw error }
        }
        if saved { error = nil; objectWillChange.send() }
        else if let failure { fail(failure) }
        else { error = dinnerText("Save did not finish. Use the pickup save controls to retry or discard the pending change.") }
        return saved
    }
    func report(_ error: Error) { fail(error) }
    private func fail(_ failure: Error) {
        switch failure {
        case DinnerPlanningError.forbidden: error = dinnerText("Planning access changed or expired. Reconnect and review again.")
        case DinnerPlanningError.paidAccessRequired: error = dinnerText("This assisted tool requires paid access. Manual dinner editing remains available.")
        case DinnerPlanningError.stalePreview: error = dinnerText("The pickup or dinner plan changed. Make a new preview before applying.")
        case DinnerPlanningError.lockedBasket: error = dinnerText("This basket is locked. Save a proposal for a purchase amendment.")
        case DinnerPlanningError.reviewRequired: error = dinnerText("Review the ingredients, portion bindings, availability and quote basis before continuing.")
        case LedgerError.allocationExceedsQuantity: error = dinnerText("That quantity is already reserved or exceeds the available amount.")
        default: error = dinnerText("Check the entered amounts, dates and required fields. Nothing has been applied.")
        }
    }
}
