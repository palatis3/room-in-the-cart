import DeviceSurfaces
import Combine
import Foundation
import CoreDomain
import LocalStore

/// Explicit identity selected from a currently authorized ingredient or need.
/// This value is presentation input, never an authorization or archive capability.
struct PantryReviewedFood: Equatable {
    let id: UUID
    let name: String
    let inventoryWorkspaceID: UUID
    let inventoryRevision: Int64

    func matches(_ state: InventoryState) -> Bool {
        state.workspaceID == inventoryWorkspaceID && state.revision == inventoryRevision
    }
}

/// Private, app-owned presentation state. The repository rechecks live authority
/// on every suspension; the generation also prevents a revoked view republishing a result.
@MainActor
final class PantryModel: ObservableObject, PantryErasureObserver {
    enum Phase: Equatable { case idle, ready, migrationRequired, accessDenied, unavailable }
    enum Notice: Equatable { case saved, saveFailed, stale, loadFailed, invalidEntry, reservationReviewRequired, insufficientFree, partialReleaseInvalid, changeTooLarge }
    enum Action { case haveEnough, someLeft, opened, move(InventoryLocation), usedUp, recount(String, UnitOfMeasure) }
    typealias Pending = PantryPendingStore.Entry

    @Published private(set) var snapshot: PantryRepository.Snapshot?
    @Published private(set) var review: PantryRepository.Review?
    @Published private(set) var pending: Pending?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: Notice?
    @Published private(set) var busy = false
    @Published private(set) var requiresFreshReview = false
    @Published private(set) var savedLotID: UUID?
    @Published private(set) var pendingWasCommitted = false
    private let repository: PantryRepository
    private let clock: () -> Date
    private let purchaseOptions: (@MainActor (InventoryState) -> [PantryRecentPurchase])?
    private let willMutateOrRecover: (@MainActor () -> Void)?
    private let didSave: (@MainActor () async -> Void)?
    private var generation = UUID()

    init(repository: PantryRepository, clock: @escaping () -> Date = Date.init,
         recentPurchases: (@MainActor (InventoryState) -> [PantryRecentPurchase])? = nil,
         willMutateOrRecover: (@MainActor () -> Void)? = nil,
         didSave: (@MainActor () async -> Void)? = nil) {
        self.repository = repository
        self.clock = clock
        self.purchaseOptions = recentPurchases
        self.willMutateOrRecover = willMutateOrRecover
        self.didSave = didSave
        repository.observeErasure(self)
    }
    func invalidatePantryPresentation(origin: UUID, initiatedHere: Bool) {
        if repository.originID == origin { accessLost() }
    }

    var canEdit: Bool { phase == .ready && snapshot != nil && !busy && pending == nil && review == nil && !requiresFreshReview }

    func verifyDigestLot(_ lot: InventoryLot, origin: UUID, inventoryRevision: Int64? = nil) async throws {
        guard canEdit, repository.originID == origin else { throw PantryDigestFailure.changed }
        let current = try await repository.loadForEditing(at: clock())
        guard canEdit, inventoryRevision.map({ $0 == current.state.revision }) ?? true,
              current.lots.first(where: { $0.id == lot.id }) == lot else { throw PantryDigestFailure.changed }
    }

    func accessLost() {
        generation = UUID()
        snapshot = nil; review = nil; pending = nil; savedLotID = nil
        phase = .accessDenied; notice = nil; busy = false; requiresFreshReview = false; pendingWasCommitted = false
    }

    /// Reappearing below the edit sheet keeps the reviewed command. An explicit refresh still reloads it.
    func loadOnAppearance(accessAllowed: Bool) async {
        guard accessAllowed, (try? repository.requireAccess()) != nil else { accessLost(); return }
        if phase == .ready, snapshot != nil, pending == nil, review != nil { return }
        await load()
    }

    func reviewConsumption(_ selections: [PantryConsumptionSelection], basis: InventoryState) async throws -> PantryConsumptionReview {
        guard canEdit, snapshot?.state == basis else { throw PantryConsumptionFailure.stale }
        let token = generation
        let result: PantryConsumptionReview
        do { result = try await repository.reviewConsumption(selections, basis: basis, at: clock()) }
        catch { try requireConsumptionAccess(); throw error }
        try requireConsumptionAccess()
        guard generation == token, canEdit, snapshot?.state == basis else { throw PantryConsumptionFailure.stale }
        return result
    }

    func usageHistory(lotID: UUID, basis: InventoryState) async throws -> [PantryUsageHistoryRow] {
        guard canEdit, snapshot?.state == basis else { throw PantryConsumptionFailure.stale }
        let token = generation
        let rows: [PantryUsageHistoryRow]
        do { rows = try await repository.usageHistory(lotID: lotID, basis: basis) }
        catch { try requireConsumptionAccess(); throw error }
        try requireConsumptionAccess()
        guard token == generation, canEdit, snapshot?.state == basis else { throw PantryConsumptionFailure.stale }
        return rows
    }

    func saveConsumption(_ consumption: PantryConsumptionReview) async throws {
        let entry = consumption.entry
        guard canEdit, let basis = snapshot?.state, basis.workspaceID == entry.command.originID,
              basis.revision == entry.reviewedInventoryRevision else { throw PantryConsumptionFailure.stale }
        let token = generation
        try requireConsumptionAccess()
        // The protected journal owns the exact identity from the first possible mutation to adoption.
        pending = entry
        do {
            pending = repository.pendingStore == nil ? entry : try repository.stagePending(entry)
        } catch {
            try requireConsumptionAccess()
            if let retained = try repository.readPending() { pending = retained }
            throw error
        }
        pendingWasCommitted = false
        await retryPending()
        guard generation == token, phase == .ready else { throw PantryConsumptionFailure.unavailable }
        guard notice != .stale else { throw PantryConsumptionFailure.stale }
        guard notice == .saved, pending == nil else { throw PantryConsumptionFailure.unavailable }
    }

    private func requireConsumptionAccess() throws {
        do { try repository.requireAccess() }
        catch PantryRepository.Failure.unauthorized {
            accessLost()
            throw PantryConsumptionFailure.unavailable
        }
    }

    func reviewReceipt(_ draft: ReceiptImportDraft) async throws -> PantryReceiptReview {
        guard canEdit, let basis = snapshot?.state else { throw PantryReceiptError.stale }
        let token = generation
        let review: PantryReceiptReview
        do { review = try await repository.reviewReceipt(draft, expected: basis, at: clock()) }
        catch let prompt as ReceiptRescanPrompt {
            guard token == generation, canEdit, snapshot?.state == basis else { throw PantryReceiptError.stale }
            throw prompt
        }
        guard token == generation, canEdit, snapshot?.state == basis else { throw PantryReceiptError.stale }
        return review
    }

    func saveReceipt(_ review: PantryReceiptReview) async throws {
        guard canEdit else { throw PantryReceiptError.stale }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        willMutateOrRecover?()
        try await repository.applyReceipt(review, at: clock())
        let result = try await repository.load(at: clock())
        guard token == generation else { throw PantryReceiptError.stale }
        snapshot = result
        await didSave?()
    }

    func priceHistory(after page: PantryPricePage? = nil) async throws -> PantryPricePage {
        guard phase != .accessDenied else { throw PantryReceiptError.stale }
        let token = generation
        let next = try await repository.pricePage(after: page)
        guard token == generation, phase != .accessDenied else { throw PantryReceiptError.stale }
        return next
    }

    func writePrice(_ evidence: PrivatePriceEvidence, expected: InventoryState) async throws {
        try await changeReceipt(expected) {
            try await repository.savePrice(evidence, expected: expected, at: clock())
        }
    }

    func verifyPriceSource(_ value: PrivatePriceEvidence, expected: InventoryState) async throws {
        let token = generation
        guard canEdit, snapshot?.state == expected else { throw PantryReceiptError.stale }
        try await repository.verifyPriceSource(value, expected: expected)
        guard token == generation, canEdit else { throw PantryReceiptError.stale }
    }

    func recordedPriceRevision(_ current: PrivatePriceEvidence, revision: Int64, expected: InventoryState) async throws -> PrivatePriceEvidence {
        let token = generation
        guard canEdit, snapshot?.state == expected else { throw PantryReceiptError.stale }
        let record = try await repository.recordedPriceRevision(current, revision: revision, expected: expected)
        guard token == generation, canEdit, snapshot?.state == expected else { throw PantryReceiptError.stale }
        return record
    }

    func priceAdjustments(for id: UUID, expected: InventoryState) async throws -> [PrivatePriceEvidence] {
        let token = generation
        guard canEdit, snapshot?.state == expected else { throw PantryReceiptError.stale }
        let adjustments = try await repository.priceAdjustments(for: id, expected: expected)
        guard token == generation, canEdit else { throw PantryReceiptError.stale }
        return adjustments
    }

    func receiptHistory(after: UUID? = nil, receiptID: UUID? = nil) async throws -> [ReceiptAcquisition] {
        guard canEdit else { throw PantryReceiptError.stale }
        let token = generation
        let page = try await repository.acquisitionHistory(receiptID: receiptID, after: after)
        guard token == generation else { throw PantryReceiptError.stale }
        return page
    }

    func latestReceiptRevision(_ selected: ReceiptAcquisition) async throws -> ReceiptAcquisition {
        guard canEdit else { throw PantryReceiptError.stale }
        let token = generation
        let latest = try await repository.latestReceiptRevision(selected)
        guard token == generation, canEdit else { throw PantryReceiptError.stale }
        return latest
    }

    func pendingSharedReceipts() async throws -> [SharedReceiptItem] {
        guard permitsReceiptSource else { throw PantryReceiptError.stale }
        let current = generation
        let rows = try await repository.withSharedReceiptScope { try await $0.pendingReceiptFiles(scope: $1, now: clock()) }
        guard current == generation, permitsReceiptSource else { throw PantryReceiptError.stale }
        return rows
    }

    func openSharedReceipt(_ item: SharedReceiptItem) async throws -> ReceiptDocumentBytes {
        guard permitsReceiptSource else { throw PantryReceiptError.stale }
        let current = generation
        let bytes = try await repository.withSharedReceiptScope { try await $0.openReceipt(item, scope: $1, now: clock()) }
        guard current == generation, permitsReceiptSource else { throw PantryReceiptError.stale }
        let kind: ReceiptDocumentKind
        switch item.descriptor.kind { case .pdf: kind = .pdf; case .image: kind = .image; case .text: kind = .text }
        return .init(data: bytes, kind: kind)
    }

    func finishSharedReceipt(_ item: SharedReceiptItem, committed: Bool) async throws {
        guard permitsReceiptSource else { throw PantryReceiptError.stale }
        try await repository.withSharedReceiptScope { try await $0.finishReceipt(item, scope: $1, committed: committed, now: clock()) }
    }

    var permitsReceiptSource: Bool { canEdit && repository.permitsReceiptSource }

    struct StapleReview {
        let state: InventoryState
        let preferences: StaplePromptPreferences
        let prompts: [StaplePrompt]
    }

    func reviewStaples(openFoodIDs: Set<UUID>, openLineNames: [String], calendar: Calendar) async throws -> StapleReview {
        guard canEdit, let snapshot else { throw PantryReceiptError.stale }
        let token = generation, now = clock()
        let preferences = try await repository.staplePreferences()
        let purchases = preferences.enabled ? try await repository.staplePurchases(expected: snapshot.state) : []
        let due = try await Self.dueStaples(purchases, lots: snapshot.lots, openFoodIDs: openFoodIDs,
            openLineNames: openLineNames, now: now, calendar: calendar)
        let prompts = due.filter { prompt in
            switch preferences.answers[prompt.latestAcquisitionID] {
            case nil: return true
            case .snooze(let until): return now >= until
            case .stillHave, .dismiss: return false
            }
        }
        guard token == generation, canEdit, self.snapshot?.state == snapshot.state else { throw PantryReceiptError.stale }
        return StapleReview(state: snapshot.state, preferences: preferences, prompts: prompts)
    }

    @concurrent private static func dueStaples(_ purchases: [ReceiptAcquisition], lots: [InventoryLot], openFoodIDs: Set<UUID>,
                                               openLineNames: [String], now: Date, calendar: Calendar) async throws -> [StaplePrompt] {
        try Task.checkCancellation()
        return try StaplePrompt.due(purchases: purchases, lots: lots, openFoodIDs: openFoodIDs,
                                    openLineNames: openLineNames, on: now, calendar: calendar)
    }

    func setStaplePrompts(_ enabled: Bool, review: StapleReview) async throws {
        guard canEdit, snapshot?.state == review.state else { throw PantryReceiptError.stale }
        try await repository.setStaplePrompts(enabled, expected: review.preferences.revision)
    }

    func answerStaple(_ answer: StaplePromptAnswer, prompt: StaplePrompt, review: StapleReview) async throws {
        guard canEdit, snapshot?.state == review.state, review.prompts.contains(prompt),
              let revision = review.preferences.revision else { throw PantryReceiptError.stale }
        try await repository.answerStaple(answer, prompt: prompt, revision: revision, expected: review.state)
    }

    var supportsReceiptAliases: Bool { repository.aliasPersonaID != nil }

    func receiptAliases(merchant: String? = nil, language: String? = nil) async throws -> [InventoryReceiptAlias] {
        guard canEdit else { throw PantryReceiptError.stale }
        let token = generation
        let aliases = try await repository.receiptAliases(merchant: merchant, language: language)
        guard token == generation, canEdit else { throw PantryReceiptError.stale }
        return aliases
    }

    func rememberReceiptAlias(_ source: ReceiptAcquisition, wording: String, language: String, state: InventoryState) async throws {
        try await changeReceipt(state) {
            try await repository.rememberReceiptAlias(source, wording: wording, language: language, expected: state, at: clock())
        }
    }

    func forgetReceiptAliases(_ aliases: [InventoryReceiptAlias], state: InventoryState) async throws {
        try await changeReceipt(state) {
            try await repository.forgetReceiptAliases(aliases, expected: state, at: clock())
        }
    }

    func correctReceiptPrice(_ original: ReceiptAcquisition, total: Money?, reviewedState: InventoryState) async throws {
        try await changeReceipt(reviewedState) {
            try await repository.correctPaidTotal(original, total: total, state: reviewedState, at: clock())
        }
    }

    private func changeReceipt(_ reviewedState: InventoryState, change: () async throws -> Void) async throws {
        guard canEdit, snapshot?.state == reviewedState else { throw PantryReceiptError.stale }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        try await change()
        let updated = try await repository.load(at: clock())
        guard token == generation else { throw PantryReceiptError.stale }
        snapshot = updated
        await didSave?()
    }

    func load() async {
        guard !busy else { return }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        // A refresh invalidates an uncommitted preview, but never changes an
        // uncertain save's original command or reviewed global revision.
        if pending == nil { review = nil }
        do {
            if repository.pendingStore != nil {
                let stored = try repository.readPending()
                if let original = pending ?? stored {
                    pending = original
                    willMutateOrRecover?()
                    let recovery = try await repository.recoverPending(original, at: clock())
                    guard token == generation else { return }
                    try await adopt(recovery, token: token)
                    return
                }
            }
            let current = try await repository.loadForEditing(at: clock())
            guard token == generation else { return }
            snapshot = current; phase = .ready
            if pending == nil { notice = nil; requiresFreshReview = false }
        } catch {
            guard token == generation else { return }
            fail(error, saving: false)
        }
    }

    var recentPurchases: [PantryRecentPurchase] {
        guard phase == .ready, let snapshot else { return [] }
        return purchaseOptions?(snapshot.state) ?? []
    }

    /// A single revision contains both the observed remaining quantity and
    /// its location. Receipt amounts never become a second acquisition.
    func prepareRecentPurchase(_ purchase: PantryRecentPurchase, amount: String, location: InventoryLocation) async {
        guard canEdit, let snapshot else { return }
        guard purchase.reviewedFood.matches(snapshot.state), recentPurchases.contains(purchase),
              let lot = snapshot.lots.first(where: { $0.id == purchase.id }),
              lot.foodID == purchase.reviewedFood.id,
              lot.source == .receipt(originID: snapshot.state.workspaceID, key: purchase.receiptKey) else {
            requiresFreshReview = true; notice = .stale; return
        }
        do {
            let now = clock()
            let count = try Self.count(amount, unit: lot.unit)
            let update = InventoryLotRevision(observation: .init(count: count, observationID: UUID(), observedAt: now), location: location)
            let command = InventoryCommand(id: UUID(), originID: snapshot.state.workspaceID, lotID: lot.id, eventID: UUID(),
                expectedRevision: lot.revision, occurredAt: now, change: .revise(update))
            await prepare(command, reviewedFood: purchase.reviewedFood)
        } catch { notice = .invalidEntry }
    }

    func prepareNewFood(name: String, existingFoodID: UUID? = nil, reviewedFood: PantryReviewedFood? = nil,
                        location: InventoryLocation, amount: String, unit: UnitOfMeasure) async {
        guard canEdit, let snapshot else { return }
        guard reviewedFood?.matches(snapshot.state) != false else {
            requiresFreshReview = true; notice = .stale; return
        }
        do {
            let foodID: UUID
            let reviewedName: String
            guard existingFoodID == nil || reviewedFood == nil else { throw InventoryError.invalid("food") }
            if let reviewedFood {
                foodID = reviewedFood.id
                reviewedName = snapshot.lots.first(where: { $0.foodID == reviewedFood.id })?.name
                    ?? reviewedFood.name.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let existingFoodID {
                // Explicit selection, never a name-based identity merge.
                guard let food = snapshot.lots.first(where: { $0.foodID == existingFoodID }) else {
                    throw InventoryError.invalid("food")
                }
                foodID = existingFoodID; reviewedName = food.name
            } else {
                foodID = UUID(); reviewedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let count = try Self.count(amount, unit: unit)
            let lotID = UUID(), origin = snapshot.state.workspaceID
            let seed = InventoryLotSeed(foodID: foodID, name: reviewedName,
                source: .manual(originID: origin, sourceID: lotID), location: location, unit: unit, count: count)
            await prepare(InventoryCommand(id: UUID(), originID: origin, lotID: lotID, eventID: UUID(),
                expectedRevision: nil, occurredAt: clock(), change: .create(seed, observationID: UUID())), reviewedFood: reviewedFood)
        } catch { notice = .invalidEntry }
    }

    func prepare(lotID: UUID, action: Action) async {
        guard canEdit, let snapshot, let lot = snapshot.lots.first(where: { $0.id == lotID }) else { return }
        do {
            let change: InventoryChange
            switch action {
            case .haveEnough: change = .count(.haveEnough, observationID: UUID())
            case .someLeft: change = .count(.someLeft, observationID: UUID())
            case .opened: change = .opened(clock())
            case .move(let location): change = .move(location)
            case .usedUp:
                let reading = InventoryCountRevision(count: .exact(Quantity(amount: .zero, unit: lot.unit, originalLiteral: "0")),
                                                     observationID: UUID(), observedAt: clock())
                change = .revise(.init(observation: reading, usage: [.init(id: UUID(), kind: .all)]))
            case .recount(let amount, let unit): change = .count(try Self.count(amount, unit: unit), observationID: UUID())
            }
            await prepare(InventoryCommand(id: UUID(), originID: snapshot.state.workspaceID, lotID: lot.id,
                eventID: UUID(), expectedRevision: lot.revision, occurredAt: clock(), change: change))
        } catch { notice = .invalidEntry }
    }

    enum ReservationAction {
        case reserve(purpose: String, amount: String, day: MealDay?)
        case release(InventoryReservation, amount: String?)
    }

    func prepareReservation(_ action: ReservationAction, lotID: UUID, basis: PantryReviewedFood) async {
        guard canEdit, let snapshot, let lot = snapshot.lots.first(where: { $0.id == lotID }) else { return }
        guard basis.matches(snapshot.state), basis.id == lot.foodID else { requiresFreshReview = true; notice = .stale; return }
        do {
            let edit: InventoryReservationEdit
            switch action {
            case let .reserve(purpose, amount, day):
                guard let quantity = try Self.count(amount, unit: lot.unit).quantity else { throw DomainError.invalidNumber }
                edit = .reserve(id: UUID(), purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines), amount: quantity, day: day)
            case let .release(claim, amount):
                guard snapshot.reservations.contains(claim), let held = claim.amount else { throw InventoryError.stale }
                let quantity: Quantity?
                if let amount {
                    guard let parsed = try Self.count(amount, unit: held.unit).quantity else { throw DomainError.invalidNumber }
                    quantity = parsed
                } else { quantity = nil }
                edit = .release(id: claim.id, expectedRevision: claim.revision, amount: quantity)
            }
            try edit.validate()
            await prepare(InventoryCommand(id: UUID(), originID: snapshot.state.workspaceID, lotID: lot.id,
                eventID: UUID(), expectedRevision: lot.revision, occurredAt: clock(), change: .reservation(edit)), reviewedFood: basis)
        } catch { notice = .invalidEntry }
    }

    func prepare(_ command: InventoryCommand, reviewedFood: PantryReviewedFood? = nil) async {
        guard canEdit else { return }
        let token = generation
        busy = true; notice = nil; savedLotID = nil
        defer { if token == generation { busy = false } }
        do {
            let result = try await repository.review(command, at: clock())
            guard token == generation else { return }
            guard reviewedFood?.matches(result.before.state) != false else {
                snapshot = result.before; requiresFreshReview = true; notice = .stale; return
            }
            snapshot = result.before; review = result; requiresFreshReview = false
        } catch {
            guard token == generation else { return }
            if error as? InventoryError == .invalid("reservationExceedsFree") || error as? InventoryError == .invalid("reservationWouldMoveOtherFood") {
                notice = .insufficientFree
            } else if error as? InventoryError == .invalid("partialRelease") { notice = .partialReleaseInvalid }
            else if error as? InventoryError == .capacity { notice = .changeTooLarge }
            else if error is DomainError { notice = .invalidEntry }
            else if let inventoryError = error as? InventoryError, case .invalid = inventoryError { notice = .invalidEntry }
            else { fail(error, saving: false) }
        }
    }

    func cancelReview() {
        guard !busy, pending == nil, review != nil else { return }
        review = nil; notice = nil; requiresFreshReview = false
    }

    func confirmReview(acknowledgingReservations: Bool) async {
        guard !busy, pending == nil, let review else { return }
        guard review.affectedReservations.isEmpty || acknowledgingReservations else {
            notice = .reservationReviewRequired; return
        }
        pending = Pending(command: review.command, reviewedInventoryRevision: review.before.state.revision)
        pendingWasCommitted = false
        if repository.pendingStore != nil {
            do {
                pending = try repository.stagePending(review.command, reviewedInventoryRevision: review.before.state.revision)
            } catch {
                // An atomic write may have succeeded before protection failed.
                // Keep the exact candidate; retry reconciles it, never recreates
                // a missing file that another editor could have discarded.
                let stagingError = error
                do {
                    if let retained = try repository.readPending() {
                        pending = retained
                        if retained.command != review.command { self.review = nil }
                    }
                } catch { fail(error, saving: true); return }
                fail(stagingError, saving: true)
                return
            }
        }
        await retryPending()
    }

    func retryPending() async {
        guard !busy, let pending else { return }
        let token = generation
        busy = true; notice = nil
        defer { if token == generation { busy = false } }
        willMutateOrRecover?()
        do {
            if repository.pendingStore != nil {
                let recovery = try await repository.recoverPending(pending, at: clock(), commitIfUnapplied: true)
                guard token == generation else { return }
                try await adopt(recovery, token: token)
                return
            }
            let result = try await repository.apply(pending, at: clock())
            guard token == generation else { return }
            snapshot = result.current; phase = .ready; self.pending = nil; review = nil
            requiresFreshReview = false; notice = .saved; savedLotID = pending.command.lotID
            await didSave?()
        } catch {
            guard token == generation else { return }
            fail(error, saving: true)
        }
    }

    /// Only a definite stale rejection can abandon a submitted intent. A transport/
    /// disk/readback failure might have committed, so it requires exact retry first.
    func discardStaleReview() async {
        guard !busy, requiresFreshReview else { return }
        if repository.pendingStore != nil, let pending {
            let token = generation
            busy = true
            defer { if token == generation { busy = false } }
            willMutateOrRecover?()
            do {
                let recovery = try await repository.recoverPending(pending, at: clock(), discardIfUnapplied: true)
                guard token == generation else { return }
                try await adopt(recovery, token: token)
            } catch {
                guard token == generation else { return }
                fail(error, saving: true)
            }
        } else {
            pending = nil; review = nil; notice = nil; requiresFreshReview = false
            await load()
        }
    }

    private func adopt(_ recovery: PantryRepository.PendingRecovery, token: UUID) async throws {
        guard token == generation else { return }
        switch recovery {
        case .waiting(let entry, let current):
            snapshot = current; phase = .ready; pending = entry; review = nil; pendingWasCommitted = false
            requiresFreshReview = current.state.revision != entry.reviewedInventoryRevision
            notice = requiresFreshReview ? .stale : .saveFailed
            await didSave?()
        case .cleared(let current):
            snapshot = current; phase = .ready; pending = nil; review = nil; savedLotID = nil
            pendingWasCommitted = false; requiresFreshReview = false; notice = nil
            await didSave?()
        case .committed(let entry, let result):
            // Current heads are adopted before durable acknowledgment. Cleanup
            // failure keeps the original pending operation blocked for exact retry.
            snapshot = result.current; phase = .ready; pendingWasCommitted = true; requiresFreshReview = false
            if let entry {
                pending = entry
                do { try repository.finishPendingAdoption(entry, result: result) }
                catch {
                    // Acknowledgment/cleanup does not decide whether the inventory
                    // changed. Readers must adopt this known current state while
                    // the exact original journal stays blocked for cleanup retry.
                    await didSave?()
                    guard token == generation else { return }
                    throw error
                }
            }
            // Reserving or releasing changes the claim, so its receipt can have no lot head.
            let reviewedLotID = entry?.command.lotID ?? pending.flatMap {
                $0.operationID == result.receipt.operationID ? $0.command.lotID : nil
            }
            pending = nil; review = nil; requiresFreshReview = false
            pendingWasCommitted = false; notice = .saved
            savedLotID = reviewedLotID ?? result.receipt.heads.first { $0.key.kind == .lot }?.key.id
            await didSave?()
        }
    }

    private func fail(_ error: Error, saving: Bool) {
        if let failure = error as? PantryRepository.Failure {
            switch failure {
            case .unauthorized, .wrongWorkspace:
                accessLost(); return
            case .inactive:
                snapshot = nil; review = nil; pending = nil; phase = .migrationRequired; notice = nil; return
            case .inconsistentSnapshot, .invalidProvenance, .pendingUnavailable: break
            }
        }
        if error as? ComparisonStoreError == .erased {
            accessLost(); return
        }
        if error as? ComparisonStoreError == .staleInventory || error as? InventoryError == .stale || error as? PantryConsumptionFailure == .stale {
            requiresFreshReview = true; notice = .stale
            return
        }
        if saving { notice = .saveFailed }
        else { snapshot = nil; phase = .unavailable; notice = .loadFailed }
    }

    private static func count(_ literal: String, unit: UnitOfMeasure) throws -> InventoryCount {
        guard literal.utf8.count <= 64 else { throw DomainError.invalidNumber }
        return try DinnerEntry.quantity(literal, unit: unit).map(InventoryCount.exact) ?? .unknown
    }
}
