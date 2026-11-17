import Foundation
import Combine
import CoreDomain

/// Decisions amend one retained ingredient-use event. All permissions, causal
/// count checks, receipts and writes remain in PantryCookSession.
@MainActor final class CookResolutionEditorModel: ObservableObject {
    enum Notice { case unavailable, invalid, changed, uncertain, saved }
    enum Failure: Error { case incomplete }
    @Published private(set) var context: PantryCookResolution.Context?
    @Published private(set) var review: PantryCookResolution.Review?
    @Published private(set) var busy = false
    @Published private(set) var attempted = false
    @Published private(set) var notice: Notice?
    @Published private(set) var eventID: UUID?
    @Published private(set) var lotID: UUID?
    @Published var action: PantryCookResolution.Action?
    @Published var usedKnown = false
    @Published var usedAmount = ""
    @Published var remainingAmount = ""
    @Published var unit: UnitOfMeasure = .count
    private var session: PantryCookSession?
    private var shopID: UUID?
    private var mealID: UUID?
    private var generation = UUID()
    private var authorize: () -> Bool = { false }
    var hasAccess: Bool { authorize() }
    var canEdit: Bool { hasAccess && context != nil && review == nil && !attempted && !busy }
    var actions: Set<PantryCookResolution.Action> {
        guard hasAccess, let context, let eventID else { return [] }
        return context.actions(eventID: eventID, lotID: lotID)
    }
    var selectedPart: CookCompletionDraft.Part? { context?.record.draft.parts.first { $0.id == eventID } }
    var selectedLot: InventoryLot? { context?.lots.first { $0.id == lotID } }
    var batchIsFixed: Bool {
        if let part = selectedPart, case .lot = part.use { return true }
        return false
    }
    func invalidate() {
        generation = UUID(); context = nil; review = nil; session = nil; authorize = { false }
        eventID = nil; lotID = nil; action = nil; usedAmount = ""; remainingAmount = ""
        busy = false; attempted = false; notice = nil
    }
    func open(session: PantryCookSession, shopID: UUID, mealID: UUID, authorize: @escaping () -> Bool) async {
        invalidate(); self.session = session; self.shopID = shopID; self.mealID = mealID; self.authorize = authorize
        await reload()
    }
    func reload() async {
        guard let session, let shopID, let mealID, hasAccess, !busy else { return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            let value = try await session.loadResolutions(shopID: shopID, mealID: mealID)
            guard token == generation, hasAccess else { invalidate(); return }
            context = value; review = nil; attempted = false; notice = nil
            selectEvent(value.remainingEventIDs.first, whileLoading: true)
        } catch {
            guard token == generation else { return }
            if !hasAccess { invalidate() } else { notice = .unavailable }
        }
    }
    func selectEvent(_ id: UUID?) { selectEvent(id, whileLoading: false) }
    private func selectEvent(_ id: UUID?, whileLoading: Bool) {
        guard (canEdit || whileLoading), id == nil || context?.remainingEventIDs.contains(id!) == true else { return }
        eventID = id; action = nil; usedKnown = false; usedAmount = ""; remainingAmount = ""
        if let part = selectedPart, case .lot(let batch, _, _) = part.use { lotID = batch } else { lotID = nil }
        unit = selectedLot?.unit ?? .count
    }
    func selectLot(_ id: UUID?) {
        guard canEdit, !batchIsFixed, id == nil || context?.lots.contains(where: { $0.id == id }) == true else { return }
        lotID = id; action = nil; usedKnown = false; usedAmount = ""; remainingAmount = ""
        unit = selectedLot?.unit ?? .count
    }
    func decision() throws -> PantryCookResolution.Decision {
        guard canEdit, let action, actions.contains(action) else { throw Failure.incomplete }
        if action == .outsidePantry { return .outsidePantry }
        guard let lotID else { throw Failure.incomplete }
        let used: Quantity?
        if usedKnown || action == .deduct {
            guard let entered = try LedgerEntry.quantity(usedAmount, unit), entered.amount > .zero else { throw Failure.incomplete }
            used = entered
        } else { used = nil }
        switch action {
        case .outsidePantry: return .outsidePantry
        case .alreadyIncluded: return .alreadyIncluded(lotID: lotID, used: used)
        case .deduct:
            guard let used else { throw Failure.incomplete }
            return .deduct(lotID: lotID, used: used)
        case .recount:
            guard let remaining = try LedgerEntry.quantity(remainingAmount, unit), remaining.amount >= .zero else { throw Failure.incomplete }
            return .recount(lotID: lotID, remaining: remaining, used: used)
        }
    }
    func prepare() async {
        guard let session, let context, let eventID, canEdit else { return }
        let decision: PantryCookResolution.Decision
        do { decision = try self.decision() } catch { notice = .invalid; return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            let value = try await session.reviewResolution(context, eventID: eventID, decision: decision)
            guard token == generation, hasAccess else { invalidate(); return }
            review = value; notice = nil
        } catch {
            guard token == generation else { return }
            if !hasAccess { invalidate() } else { notice = .changed }
        }
    }
    func keepEditing() {
        guard hasAccess, !attempted, !busy else { return }
        review = nil; notice = nil
    }
    func confirm() async {
        guard let session, let review, hasAccess, !busy else { return }
        let token = generation; busy = true; attempted = true
        defer { if token == generation { busy = false } }
        do {
            try await session.applyResolution(review)
            guard token == generation, hasAccess else { invalidate(); return }
            busy = false
            await reload()
            if token == generation, hasAccess, context?.remainingEventIDs.contains(review.eventID) == false { notice = .saved }
        } catch {
            guard token == generation else { return }
            if !hasAccess { invalidate() } else { notice = .uncertain }
        }
    }
}
