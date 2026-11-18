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
    func change(key: String, reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis?,
                _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool
}

extension DinnerWorkspaceStore {
    func change(key: String, reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis?,
                _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        // A store without the canonical gated save path cannot honor this proof.
        guard reviewedPantryBasis == nil else { return false }
        return await change(key: key, edit)
    }
}

/// No imported document can provide this feature's authority. The coordinator supplies
/// a fresh runtime binding for each preview, metadata save, and final Apply.
@MainActor final class DinnerFeatureModel: ObservableObject {
    typealias AccessProvider = (UUID) -> DinnerAccessContext?
    @Published private(set) var preview: DinnerPreview?
    private var pantryPreviewReview: (proposalID: UUID, basis: LedgerCanonicalPackStockEvidence.Basis)?
    var reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis? {
        guard pantryPreviewReview?.proposalID == preview?.proposal.id else { return nil }
        return pantryPreviewReview?.basis
    }
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    let store: any DinnerWorkspaceStore
    let accessProvider: AccessProvider
    let phaseProvider: (UUID) -> BasketPhase
    let ideaCatalog: [MealTemplate]
    let clock: () -> Date
    private(set) weak var repeatWeekPickup: PickupModel?
    private weak var swapPickup: PickupModel?
    private var swapReview: DinnerSwapReview?
    var currentSwapReview: DinnerSwapReview? {
        guard let swapReview, canReviewPreview, swapReview.preview.proposal.id == preview?.proposal.id else { return nil }
        return swapReview
    }
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
        if let repeated = preview.proposal.repeatWeek {
            guard let identity = editorIdentity, canReadRepeatSources(repeated.sourceShopIDs, identity: identity),
                  repeated.staples.isEmpty || access.hasPaidTools else { return false }
        }
        return namespace == preview.proposal.namespace && access.actorID == preview.proposal.authorID &&
            preview.proposal.preferenceRevision == state.preferences(for: access)?.revision
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
    func access(for shopID: UUID) throws -> DinnerAccessContext {
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
    @discardableResult func prepare(_ changes: [DinnerLedgerChange], tool: DinnerPlanningTool = .manual, isolated: Bool = false, expectedRevision: UUID? = nil, reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis? = nil) -> Bool {
        guard editable, let shop else { return false }
        do {
            if let expectedRevision, expectedRevision != shop.revisionID { throw DinnerPlanningError.stalePreview }
            preview = try DinnerPlanningEngine.preview(changes: changes, tool: tool, ledger: shop,
                state: state, access: access(for: shop.id), phase: phaseProvider(shop.id), at: clock(), isolated: isolated)
            pantryPreviewReview = reviewedPantryBasis.flatMap { basis in preview.map { ($0.proposal.id, basis) } }
            error = nil; notice = nil; return true
        } catch { preview = nil; fail(error); return false }
    }
    func installRepeatWeek(_ value: DinnerPreview, pantryBasis: DinnerPantrySupply.Basis?, pickup: PickupModel) {
        repeatWeekPickup = pickup
        preview = value
        pantryPreviewReview = pantryBasis.map { (value.proposal.id, $0) }
        error = nil
        notice = nil
    }
    @discardableResult func installSwap(_ value: DinnerSwapReview, pickup: PickupModel) -> Bool {
        let reviewed = value.preview.proposal
        guard let shop, let id = reviewed.swapOriginalID, id == value.original.id,
              shop.id == reviewed.shopID, shop.revisionID == reviewed.baseRevisionID,
              state.revisionID == reviewed.planningRevisionID, phaseProvider(shop.id) == .draft,
              Self.swapReadAllowed(pickup, store: store, affected: [id], shopID: shop.id) else { fail(DinnerPlanningError.stalePreview); return false }
        swapPickup = pickup
        swapReview = value
        preview = value.preview
        pantryPreviewReview = value.pantryBasis.map { (reviewed.id, $0) }
        error = nil
        notice = nil
        return true
    }

    private static func swapReadAllowed(_ pickup: PickupModel, store: any DinnerWorkspaceStore, affected meals: Set<UUID>, shopID: UUID) -> Bool {
        guard pickup.recoveryLedger === store, pickup.ready, !pickup.hasPendingSave, !pickup.saving,
              !pickup.pantryIsActive || pickup.pantryReadIsCurrent else { return false }
        guard let source = pickup.journeys.first(where: { $0.id == shopID }) else { return true }
        return source.closedAt == nil && source.mealRecovery?.domain.events.contains(where: { meals.contains($0.request.target.id) }) != true &&
            source.cookedMeals?.contains(where: { $0.isActive && meals.contains($0.draft.meal.id) }) != true
    }

    func latestUndoableSwap(occurrenceID: UUID) -> DinnerApplyReceipt? {
        guard let shop, let access = try? access(for: shop.id), case .local(let workspaceID) = access.scope else { return nil }
        let namespace = "local:\(workspaceID.uuidString)"
        return state.applyReceipts.last { receipt in
            receipt.proposal.namespace == namespace && receipt.proposal.shopID == shop.id && receipt.appliedBy == access.actorID && receipt.swapUndoRevisionID == nil &&
                (receipt.swapEffect?.original.id == occurrenceID || receipt.swapEffect?.replacementID == occurrenceID)
        }
    }

    private func swapAuthorization(_ proposal: DinnerProposal, pickup: PickupModel?, meals: Set<UUID>,
                                   usesCanonicalStock: Bool) -> (@MainActor () -> Bool) {
        let identity = editorIdentity
        let accessProvider = accessProvider
        let phase = phaseProvider
        let clock = clock
        return { [weak ledger = store as? LedgerModel, weak pickup] in
            guard let identity, let pickup, let ledger, let access = accessProvider(proposal.shopID),
                  ledger.workspace.selectedShopID == proposal.shopID,
                  case .local(let origin) = access.scope, origin == ledger.sourceWorkspaceID,
                  access.scope == identity.scope, access.actorID == identity.actorID, access.actorID == proposal.authorID,
                  (try? access.validate(shopID: proposal.shopID, at: clock(), applying: true)) != nil,
                  phase(proposal.shopID) == .draft, pickup.pantryIsActive == usesCanonicalStock else { return false }
            return Self.swapReadAllowed(pickup, store: ledger, affected: meals, shopID: proposal.shopID)
        }
    }

    @discardableResult func undoSwap(_ reviewed: DinnerApplyReceipt, pickup: PickupModel) async -> Bool {
        guard let shop, let effect = reviewed.swapEffect, let workspaceID = localIdeaWorkspaceID else { return false }
        do {
            let actor = try access(for: shop.id)
            if let saved = state.applyReceipts.first(where: { $0.id == reviewed.id && $0.swapUndoRevisionID != nil }) {
                guard saved.proposal == reviewed.proposal, saved.swapEffect == effect, saved.appliedBy == actor.actorID,
                      saved.proposal.shopID == shop.id, case .local(let origin) = actor.scope, origin == workspaceID
                else { throw DinnerPlanningError.forbidden }
                return true
            }
            let stock = try DinnerPantrySupply.read(pickup: pickup, workspaceID: workspaceID,
                linkedWorkspaceID: pickup.recoveryLedger?.sourceWorkspaceID, shopID: shop.id)
            let authorize = swapAuthorization(reviewed.proposal, pickup: pickup, meals: [effect.original.id, effect.replacementID],
                                              usesCanonicalStock: stock != nil)
            return await mutate(key: "undo-dinner-swap-\(reviewed.id)", shopID: shop.id, reviewedPantryBasis: stock?.basis,
                                reauthorize: authorize) { workspace, index, access, now in
                let current = workspace.shops[index]
                let touched = Set(effect.original.ingredientContributionIDs + effect.replacement.ingredientContributionIDs)
                if let journey = pickup.journeys.first(where: { $0.id == current.id }), let context = try pickup.pantryReviewContext() {
                    // Undo removes the replacement's demand. Existing claims for the
                    // surviving original groups retain their own need identities.
                    let needs = Set(journey.needDetails.filter { $0.sourceOccurrenceID == effect.replacementID }.map(\.id))
                    let reservations = Set(context.mapping.claimLinks.filter {
                        $0.journeyIDs.contains(current.id) && needs.contains($0.legacyNeedID)
                    }.map(\.reservationID))
                    guard !context.snapshot.reservations.contains(where: { reservations.contains($0.id) && $0.state != .released })
                    else { throw DinnerPlanningError.reviewRequired("reservedMeal") }
                }
                let lineIDs = Set(current.contributions.filter { touched.contains($0.id) }.map(\.lineID))
                let later = Set(current.revisions.drop(while: { $0.id != reviewed.revisionID }).map(\.id))
                guard !workspace.packSelections.contains(where: { $0.shopID == current.id && lineIDs.contains($0.lineID) && later.contains($0.shopRevisionID) })
                else { throw DinnerPlanningError.stalePreview }
                _ = try DinnerSwapEngine.undo(reviewed, ledger: &workspace.shops[index], state: &workspace.dinnerPlanning,
                    access: access, phase: self.phaseProvider(shop.id), at: now)
            }
        } catch { fail(error); return false }
    }

    func cancelPreview() { preview = nil; pantryPreviewReview = nil; error = nil }
    func endDecision(restoring previous: DinnerPreview?, pantryBasis: LedgerCanonicalPackStockEvidence.Basis? = nil) {
        cancelPreview()
        guard let previous, shop?.id == previous.proposal.shopID, shop?.revisionID == previous.proposal.baseRevisionID,
              state.revisionID == previous.proposal.planningRevisionID else { return }
        preview = previous
        pantryPreviewReview = pantryBasis.map { (previous.proposal.id, $0) }
        if !canReviewPreview { preview = nil }
    }
    @discardableResult func applyPreview() async -> Bool {
        guard canApply, let reviewed = preview else { fail(DinnerPlanningError.forbidden); return false }
        var authorize = repeatWeekAuthorization(for: reviewed.proposal)
        if let originalID = reviewed.proposal.swapOriginalID {
            guard let detail = currentSwapReview, let pickup = swapPickup else { fail(DinnerPlanningError.stalePreview); return false }
            authorize = swapAuthorization(reviewed.proposal, pickup: pickup, meals: [originalID], usesCanonicalStock: detail.pantryBasis != nil)
        }
        let ok = await mutate(key: "dinner-apply-\(reviewed.proposal.id)", shopID: reviewed.proposal.shopID,
            reviewedPantryBasis: reviewedPantryBasis,
            reauthorize: authorize) { workspace, index, access, now in
            // The local adapter has no server commit binding. Even a caller-supplied
            // sharedCommitAuthorized bit cannot enable a shared authoritative write.
            guard case .local = access.scope else { throw DinnerPlanningError.forbidden }
            if reviewed.proposal.repeatWeek != nil {
                try self.applyRepeatWeek(reviewed.proposal, workspace: &workspace, access: access, at: now)
                return
            }
            _ = try DinnerPlanningEngine.apply(reviewed.proposal, ledger: &workspace.shops[index],
                state: &workspace.dinnerPlanning, access: access, phase: self.phaseProvider(reviewed.proposal.shopID), at: now)
        }
        if ok { preview = nil; notice = dinnerText("Dinner changes saved.") }
        return ok
    }
    @discardableResult func savePreviewAsProposal() async -> Bool {
        guard canReviewPreview, let reviewed = preview, !reviewed.proposal.isIsolatedPreview else { return false }
        let ok = await mutate(key: "dinner-proposal-\(reviewed.proposal.id)", shopID: reviewed.proposal.shopID,
            reviewedPantryBasis: reviewedPantryBasis) { workspace, _, access, now in
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
    @discardableResult func saveNote(_ note: DinnerWeekNote, replacing original: DinnerWeekNote? = nil,
                                     editor: EditorIdentity) async -> Bool {
        await mutate(key: "dinner-note-\(note.id)", shopID: note.shopID) { workspace, _, access, now in
            guard workspace.selectedShopID == editor.shopID, note.shopID == editor.shopID,
                  editor.scope == access.scope, editor.actorID == access.actorID else { throw DinnerPlanningError.forbidden }
            try workspace.dinnerPlanning.recordWeekNote(note, replacing: original, access: access, at: now)
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
    var mealPreferences: MealPreferenceProfile? {
        guard let shop, let context = try? access(for: shop.id) else { return nil }
        return state.preferences(for: context)
    }
    var ideaPatterns: [MealTemplate] {
        ideaCatalog.filter { MealEligibilityPolicy.evaluate(profile: mealPreferences, template: $0).blocked.isEmpty }.sorted {
            let left = MealEligibilityPolicy.evaluate(profile: mealPreferences, template: $0)
            let right = MealEligibilityPolicy.evaluate(profile: mealPreferences, template: $1)
            if left.eligible != right.eligible { return left.eligible }
            if left.softDifferences.count != right.softDifferences.count {
                return left.softDifferences.count < right.softDifferences.count
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    func newIdea(seed: UInt64, exclusions: [String], manual: MealTemplate? = nil) throws -> DinnerIdeaDraft {
        guard let shop else { throw DinnerPlanningError.invalid("shop") }
        _ = try access(for: shop.id)
        if let manual {
            var draft = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "manual-v1", template: manual,
                hardExclusions: exclusions, createdAt: clock())
            draft.preferenceRevision = mealPreferences?.revision
            return draft
        }
        let patterns = ideaPatterns
        guard !patterns.isEmpty else { throw DinnerPlanningError.reviewRequired("manualIdeaEntry") }
        let selected = patterns[Int(seed % UInt64(patterns.count))]
        var draft = try DinnerIdeaEngine.draft(requestID: UUID(), draftID: UUID(), catalogVersion: "reviewed-catalog-v1",
            catalog: [selected], seed: 0, householdExclusions: exclusions, at: clock())
        draft.preferenceRevision = mealPreferences?.revision
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
    func cost(of scenario: DinnerScenario, cap: CheckoutCap?) throws -> DinnerScenarioResult {
        guard let shop else { throw DinnerPlanningError.invalid("shop") }
        try access(for: shop.id).validate(shopID: shop.id, at: clock(), budget: true)
        return try DinnerScenarioEngine.evaluate(scenario, acceptedDinners: state.acceptedDinners,
            cap: cap, ledger: shop, state: state)
    }
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
        let result = try TwoStoreQuoteEngine.compare(pair, access: access(for: pair.shopID), at: clock())
        clearErrorAfterSuccessfulReview()
        return result
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
    private func mutate(key: String, shopID: UUID, reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis? = nil,
                        reauthorize: (@MainActor () -> Bool)? = nil,
                        edit: (inout LedgerWorkspace, Int, DinnerAccessContext, Date) throws -> Void) async -> Bool {
        guard editable else { return false }
        busy = true; defer { busy = false }
        var failure: Error?
        func update(_ workspace: inout LedgerWorkspace) throws {
            do {
                let current = try self.access(for: shopID)
                guard let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw DinnerPlanningError.notFound(shopID) }
                try edit(&workspace, index, current, self.clock())
            } catch { failure = error; throw error }
        }
        let saved: Bool
        if let reauthorize {
            guard let ledger = store as? LedgerModel else { fail(DinnerPlanningError.forbidden); return false }
            saved = await ledger.change(key: key, reviewedPantryBasis: reviewedPantryBasis, authorize: reauthorize, update)
        } else {
            saved = await store.change(key: key, reviewedPantryBasis: reviewedPantryBasis, update)
        }
        if saved { error = nil; objectWillChange.send() }
        else if let failure { fail(failure) }
        else { error = dinnerText("Save did not finish. Use the pickup save controls to retry or discard the pending change.") }
        return saved
    }
    func report(_ error: Error) { fail(error) }
    /// A successfully reviewed editor replaces its earlier validation feedback;
    /// this does not apply a proposal, save data, or clear a failed write.
    func clearErrorAfterSuccessfulReview() { error = nil }
    private func fail(_ failure: Error) {
        switch failure {
        case let validation as DinnerDraftValidationError: error = validation.errorDescription
        case DinnerPlanningError.forbidden: error = dinnerText("Planning access changed or expired. Reconnect and review again.")
        case DinnerPlanningError.paidAccessRequired: error = dinnerText("This assisted tool requires paid access. Manual dinner editing remains available.")
        case DinnerPlanningError.stalePreview: error = dinnerText("The pickup or dinner plan changed. Make a new preview before applying.")
        case DinnerPlanningError.lockedBasket: error = dinnerText("This basket is locked. Save a proposal for a purchase amendment.")
        case DinnerPlanningError.reviewRequired("mealPreferences"): error = dinnerText("Review ingredient and appliance details against your meal preferences.")
        case DinnerPlanningError.reviewRequired: error = dinnerText("Review the ingredients, portion bindings, availability and quote basis before continuing.")
        case LedgerError.allocationExceedsQuantity: error = dinnerText("That quantity is already reserved or exceeds the available amount.")
        default: error = dinnerText("Check the entered amounts, dates and required fields. Nothing has been applied.")
        }
    }
}
