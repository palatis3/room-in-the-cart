import Foundation
import SwiftUI
import HouseholdClient

struct SharedShopLineDraft: Identifiable, Equatable {
    let id: UUID
    var item: String; var packs: Int; var price: String; var feeEligible: Bool
    init(id: UUID = UUID(), item: String = "", packs: Int = 1, price: String = "", feeEligible: Bool = true) {
        self.id = id; self.item = item; self.packs = packs; self.price = price; self.feeEligible = feeEligible
    }
}
struct SharedShopDraft: Equatable {
    var lines: [SharedShopLineDraft] = []
    var mealEdit: SharedMealEdit?
    var scope = "wholeCheckout", capScope = "wholeCheckout"
    var complete = false
    var cap = "", fee = "", tax = "", deposits = "", discounts = ""
    var feeKind = "fixed", threshold = "", belowFee = "", aboveFee = ""
    var observedAt = Date(), expiresAt = Date().addingTimeInterval(3600)
    static func amount(_ minor: Int?) -> String {
        guard let minor else { return "" }; return String(format: "%d.%02d", minor / 100, minor % 100)
    }
    init() {}
    init(_ shop: ShopperShop) throws {
        lines = try shop.lines.map {
            guard let id = UUID(uuidString: $0.id) else { throw ClientError.invalidResponse }
            return .init(id: id, item: $0.originalItem, packs: $0.packs, price: Self.amount($0.unitPriceMinor), feeEligible: $0.feeEligible)
        }
        let quote = shop.quote
        scope = quote.scope; capScope = quote.capScope; complete = quote.complete; cap = Self.amount(quote.capMinor)
        feeKind = quote.fee.kind; fee = Self.amount(quote.fee.amountMinor); threshold = Self.amount(quote.fee.thresholdMinor)
        belowFee = Self.amount(quote.fee.belowMinor); aboveFee = Self.amount(quote.fee.aboveMinor)
        tax = Self.amount(quote.taxesMinor); deposits = Self.amount(quote.depositsMinor); discounts = Self.amount(quote.discountsMinor)
        observedAt = serviceDate(quote.observedAt) ?? .distantPast; expiresAt = serviceDate(quote.expiresAt) ?? .distantPast
    }
    @MainActor func candidate() throws -> ShopperShopCandidate {
        let money = HouseholdInboxModel.priceMinor
        let feeValue: ShopperQuote.Fee
        if feeKind == "threshold" {
            guard let value = try money(threshold) else { throw ClientError.configuration }
            feeValue = .threshold(value, below: try money(belowFee), above: try money(aboveFee))
        } else { feeValue = .fixed(try money(fee)) }
        let quote = try ShopperQuote(scope: scope, complete: complete, capMinor: money(cap), capScope: capScope, fee: feeValue,
            taxesMinor: money(tax), depositsMinor: money(deposits), discountsMinor: money(discounts), observedAt: observedAt, expiresAt: expiresAt)
        return try .init(quote: quote, lines: lines.map { try .init(lineId: $0.id, originalItem: $0.item.trimmingCharacters(in: .whitespacesAndNewlines),
            packs: $0.packs, unitPriceMinor: money($0.price), feeEligible: $0.feeEligible) })
    }
}
struct SharedShopReview: Equatable {
    let shopID: String; let kind: String; let base: CommandBase; let candidate: ShopperShopCandidate?
    var mealEdit: SharedMealEdit? = nil
    var transfer: SharedShopTransfer? = nil
}

struct SharedShopTransfer: Equatable {
    let adultID: UUID
    let fromLabel: String
    let toLabel: String
}

/// The shared shop is explicitly entered and reviewed here. It never reads the private local ledger.
@MainActor final class HouseholdShopModel: ObservableObject {
    @Published private(set) var scope: HouseholdBootstrap
    @Published private(set) var deliveryRecord: SharedDeliveryPage?
    @Published private(set) var financialEntries: [ShopperFinancialEntry]?
    @Published private(set) var lastShopSync: Date?
    @Published private(set) var shop: ShopperShop?
    @Published private(set) var busy = false
    @Published private(set) var authorized = true
    @Published private(set) var editing = false
    @Published private(set) var creatingAnother = false
    @Published private(set) var requiresRefresh = false
    @Published private(set) var review: SharedShopReview?
    @Published private(set) var pending: PendingOperation?
    @Published private(set) var delivery: ShopperDelivery = .none
    @Published private(set) var reviewedCurrentFacts = false
    @Published private(set) var notice: String?
    @Published var draft = SharedShopDraft() { didSet { review = nil; acknowledged = false } }
    @Published var acknowledged = false
    let householdID: String; let memberID: String
    private let service: HouseholdService
    private let outbox: OperationOutbox
    private let onConfirmed: @MainActor () async -> Void
    private let onAccessEnded: @MainActor () async -> Void
    private var generation = UUID()
    private var attempts = 0
    private var retryAfter = Date.distantPast
    init(scope: HouseholdBootstrap, service: HouseholdService, outbox: OperationOutbox,
         onConfirmed: @escaping @MainActor () async -> Void, onAccessEnded: @escaping @MainActor () async -> Void) {
        self.scope = scope; self.service = service; self.outbox = outbox; self.onConfirmed = onConfirmed; self.onAccessEnded = onAccessEnded
        householdID = scope.household.id; memberID = scope.memberId
    }
    var canCreate: Bool { authorized && !requiresRefresh && scope.grantId == nil && scope.role == "organizer" && scope.capabilities.contains("household_admin") && scope.shopId == nil && scope.selectionRequired != true }
    var canManage: Bool { authorized && !requiresRefresh && scope.grantId == nil && scope.role == "shopper" && scope.capabilities.contains("shopper_commands") && scope.shopId != nil }
    var canReadDelivery: Bool { canManage && scope.capabilities.contains("delivery_evidence") }
    var canStartAnother: Bool {
        authorized && !requiresRefresh && scope.canSelectShop == true && scope.grantId == nil &&
        scope.capabilities.contains("household_admin") && !canCreate
    }
    func beginAnotherShop() {
        guard canStartAnother, !busy, !editing, pending == nil else { return }
        draft = .init(); creatingAnother = true; editing = true
    }
    func updateScope(_ value: HouseholdBootstrap) {
        guard value.household.id == householdID, value.memberId == memberID, value.grantId == nil else { clear(); return }
        if scope.shopId != value.shopId || scope.role != value.role || Set(scope.capabilities) != Set(value.capabilities) {
            financialEntries = nil; deliveryRecord = nil; review = nil; acknowledged = false
            draft = .init()
            editing = false; creatingAnother = false
            shop = nil
            lastShopSync = nil
        }
        scope = value
    }
    func load() async {
        guard authorized, !busy else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            try await refreshFacts(start: start)
            if pending == nil {
                let saved = try await outbox.operations(); guard start == generation else { return }
                if let operation = saved.first(where: { $0.householdID == householdID && $0.memberID == memberID && $0.targetsShop(scope.shopId, includeCreation: scope.capabilities.contains("household_admin")) }) {
                    pending = operation
                    let matches = await service.matches(operation, memberID: memberID)
                    guard start == generation else { return }
                    delivery = matches ? .waiting : .needsReview
                }
            }
            if pendingDelivery && !canReadDelivery { delivery = .needsReview }
            reviewedCurrentFacts = pending != nil && (!pendingDelivery || !canReadDelivery)
        } catch { await handle(error, start: start) }
    }
    private func refreshFacts(start: UUID) async throws {
        let fresh = try await service.bootstrap(); guard start == generation else { throw ClientError.cancelled }
        guard fresh.household.id == householdID, fresh.memberId == memberID, fresh.grantId == nil,
              fresh.capabilities.contains("household_admin") || fresh.role == "shopper" else { throw ClientError.accessEnded }
        updateScope(fresh)
        if fresh.role == "shopper", fresh.capabilities.contains("shopper_commands"), let id = fresh.shopId {
            let value = try await service.shopperShop(shopID: id)
            guard start == generation, scope == fresh else { throw ClientError.cancelled }
            if shop != value {
                deliveryRecord = nil
                review = nil; acknowledged = false
                if editing {
                    draft = .init(); editing = false; creatingAnother = false
                    notice = ht("The shared shop changed. Open the current revision to edit again.")
                }
            }
            shop = value
            lastShopSync = Date()
        } else { shop = nil; deliveryRecord = nil; lastShopSync = nil }
        requiresRefresh = false
    }
    func loadDelivery() async {
        guard canReadDelivery, let shop, shop.placedRevision != nil, !busy else { return }
        let start = generation
        busy = true; defer { busy = false }
        do {
            let page = try await service.deliveryEvidence(shopID: shop.shopId)
            guard start == generation, canReadDelivery, scope.shopId == shop.shopId, self.shop == shop,
                  UUID(uuidString: shop.shopId) == page.shopId else { return }
            guard page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch,
                  page.placedRevision == shop.placedRevision else {
                throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
            }
            deliveryRecord = page; notice = nil
            if pendingDelivery { reviewedCurrentFacts = true }
        } catch {
            guard start == generation else { return }
            deliveryRecord = nil
            await handle(error, start: start)
        }
    }
    func coverage(reviewed page: SharedDeliveryPage) async throws -> SharedDeliveryCoverage {
        guard canReadDelivery, deliveryRecord == page else { throw ClientError.accessEnded }
        let start = generation
        let result = try await service.deliveryCoverage(reviewed: page)
        guard canReadDelivery, start == generation, deliveryRecord == page else { throw ClientError.cancelled }
        return result
    }
    var pendingDelivery: Bool {
        guard let pending, let envelope = try? JSONDecoder().decode(CommandEnvelope.self, from: pending.bytes) else { return false }
        return envelope.kind.hasPrefix("delivery.")
    }

    func saveDelivery(_ edit: SharedDeliveryEdit, reviewed page: SharedDeliveryPage) async -> Bool {
        guard canReadDelivery, !busy, pending == nil, let shop, shop.phase == "placed", scope.shopId == shop.shopId,
              page == deliveryRecord, UUID(uuidString: shop.shopId) == page.shopId, page.shopRevision == shop.shopRevision,
              page.authorityEpoch == shop.authorityEpoch, page.placedRevision == shop.placedRevision else { return false }
        busy = true; let start = generation
        defer { busy = false }
        do {
            let body = try edit.body(reviewed: page)
            let window = try await service.replayWindow()
            guard start == generation, scope.shopId == shop.shopId, self.shop == shop, deliveryRecord == page, canReadDelivery else { return false }
            let envelope = CommandEnvelope(replayWindow: window.id, shopId: shop.shopId, kind: edit.kind,
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: body)
            try await queueAndDeliver(envelope, start: start)
            guard start == generation else { return false }
            if case .confirmed = delivery { deliveryRecord = nil; return true }
            return pending != nil
        } catch { await handle(error, start: start); return false }
    }
    func loadFinancialEntries() async {
        guard canManage, let id = scope.shopId, !busy else { return }
        busy = true
        financialEntries = nil
        let start = generation
        defer { busy = false }
        do {
            let entries = try await service.shopperFinancialEvidence(shopID: id)
            guard generation == start, scope.shopId == id, canManage else { return }
            financialEntries = entries
            notice = nil
        } catch { await handle(error, start: start) }
    }
    func beginEditing() {
        guard authorized, !busy, pending == nil else { return }
        creatingAnother = false
        if canCreate { draft = .init(); editing = true }
        else if canManage, let shop, shop.phase == "draft" {
            do { draft = try .init(shop); editing = true } catch { notice = ht("The shared shop could not be opened for editing. Refresh before trying again.") }
        }
    }
    func cancelEditing() { guard !busy, pending == nil else { return }; editing = false; creatingAnother = false; review = nil; acknowledged = false }
    func reviewDraft() {
        guard authorized, !busy, pending == nil, editing else { return }
        do {
            guard draft.expiresAt > Date(), draft.observedAt <= Date().addingTimeInterval(300) else { throw ClientError.configuration }
            let enteredCandidate = try draft.candidate()
            let candidate = try ShopperShopCandidate(quote: enteredCandidate.quote, lines: enteredCandidate.lines,
                                                     reviewedStoreBasisRevision: shop?.storeBasisRevision)
            if canCreate || (creatingAnother && canStartAnother) { review = .init(shopID: UUID().uuidString.lowercased(), kind: "shop.create", base: .init(shopRevision: 0, authorityEpoch: 0), candidate: candidate) }
            else if canManage, let shop, shop.phase == "draft" {
                var reviewedMeal = draft.mealEdit
                if let edit = reviewedMeal {
                    guard let meals = shop.meals else { throw ClientError.configuration }
                    let currentMealRevision = meals.first(where: { $0.id == edit.occurrenceID })?.revision
                    if let reviewedBase = edit.baseMealRevision, reviewedBase != currentMealRevision { throw ClientError.configuration }
                    reviewedMeal?.baseMealRevision = currentMealRevision
                    if let meal = edit.meal {
                        try meal.validatePlanning()
                        guard !meal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meal.title.count <= 240,
                              (1...1000).contains(meal.portions), ["dinner", "lunch", "side"].contains(meal.kind),
                              sharedMealDate(meal.day) != nil else { throw ClientError.configuration }
                    } else if !meals.contains(where: { $0.id == edit.occurrenceID }) { throw ClientError.configuration }
                }
                review = .init(shopID: shop.shopId, kind: "shop.patch", base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch), candidate: candidate, mealEdit: reviewedMeal)
            } else { return }
            acknowledged = false; notice = nil
        } catch { notice = ht("Review every item and price. Leave unknown costs blank, enter a fee threshold when selected, and set a future quote expiry.") }
    }
    func reviewTransfer(_ assignment: ShopperAssignment, to adultID: UUID) {
        guard authorized, !busy, !editing, pending == nil, !requiresRefresh, scope.grantId == nil,
              scope.capabilities.contains("household_admin"), scope.shopId.flatMap(UUID.init(uuidString:)) == assignment.shopId,
              assignment.phase != "closed", assignment.shopperId != adultID,
              let from = assignment.adults.first(where: { $0.id == assignment.shopperId }),
              let to = assignment.adults.first(where: { $0.id == adultID }) else { return }
        review = .init(shopID: assignment.shopId.uuidString.lowercased(), kind: "shop.transferAuthority",
            base: .init(shopRevision: assignment.shopRevision, authorityEpoch: assignment.authorityEpoch), candidate: nil,
            transfer: SharedShopTransfer(adultID: adultID, fromLabel: from.label, toLabel: to.label))
        acknowledged = false
    }
    func reviewPhaseChange(_ kind: String) {
        guard canManage, !busy, pending == nil, let shop,
              (kind == "shop.freeze" && shop.phase == "draft") || (kind == "shop.reopen" && shop.phase == "frozen") else { return }
        editing = false; acknowledged = false
        review = .init(shopID: shop.shopId, kind: kind, base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch), candidate: nil)
    }
    func applyReviewed() async {
        guard authorized, !busy, pending == nil, acknowledged, let review else { return }
        if let candidate = review.candidate, (serviceDate(candidate.quote.expiresAt) ?? .distantPast) <= Date() {
            self.review = nil; acknowledged = false; notice = ht("The reviewed quote expired. Update its evidence and review again."); return
        }
        busy = true; defer { busy = false }; let start = generation
        do {
            let window = try await service.replayWindow(); guard start == generation else { return }
            guard self.review == review, acknowledged else { return }
            var body = try review.candidate?.commandBody() ?? [:]
            if let transfer = review.transfer { body["newShopperId"] = .string(transfer.adultID.uuidString.lowercased()) }
            if let edit = review.mealEdit { body["mealEdit"] = try edit.commandValue() }
            let envelope = CommandEnvelope(replayWindow: window.id, shopId: review.shopID, kind: review.kind, base: review.base, body: body)
            try await queueAndDeliver(envelope, start: start)
        } catch { await handle(error, start: start) }
    }
    private func queueAndDeliver(_ envelope: CommandEnvelope, start: UUID) async throws {
        let actorScope = scope
        let operation = try await service.prepare(envelope: envelope, bootstrap: actorScope)
        guard start == generation, scope == actorScope else { throw ClientError.cancelled }
        try await outbox.append(operation)
        guard start == generation, scope == actorScope else { throw ClientError.cancelled }
        pending = operation; delivery = .waiting; attempts = 0; reviewedCurrentFacts = false
        await deliver(operation, start: start)
    }
    func retry() async {
        guard authorized, !busy, let pending, delivery == .waiting else { return }
        guard Date() >= retryAfter, attempts < 5 else { notice = ht("Wait before retrying, or review this action after several failed attempts."); return }
        busy = true; defer { busy = false }; await deliver(pending, start: generation)
    }
    private func deliver(_ operation: PendingOperation, start: UUID) async {
        attempts += 1
        do {
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
            let receipt = try await service.executeSharedShop(operation); guard start == generation else { return }
            guard receipt.shopId == envelope.shopId, receipt.kind == envelope.kind else { throw ClientError.invalidResponse }
            delivery = .confirmed(receipt); pending = nil; editing = false; creatingAnother = false; review = nil; acknowledged = false; requiresRefresh = true
            do { try await outbox.remove(operation.id) } catch { notice = ht("The shared shop change was confirmed. Local retry cleanup needs another attempt.") }
            guard start == generation else { return }
            do {
                if envelope.kind == "shop.create", scope.canSelectShop == true, let id = UUID(uuidString: receipt.shopId) {
                    _ = try await service.selectShop(id)
                }
                try await refreshFacts(start: start); await onConfirmed()
            }
            catch {
                guard start == generation else { return }
                switch error as? ClientError {
                case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _): await handle(error, start: start)
                case .cancelled: break
                default: notice = ht("The shared shop change was confirmed. Refresh the household to see the latest state.")
                }
            }
        } catch {
            guard start == generation else { return }
            if let error = error as? ClientError, let delay = RetryPolicy().delay(attempt: attempts, error: error) { retryAfter = Date().addingTimeInterval(delay) }
            else { delivery = .needsReview; reviewedCurrentFacts = false }
            await handle(error, start: start)
        }
    }
    func clearPendingAfterReview() async {
        guard authorized, !busy, reviewedCurrentFacts, let pending else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            try await outbox.remove(pending.id); guard start == generation else { return }
            self.pending = nil; delivery = .none; review = nil; acknowledged = false; attempts = 0
        } catch { await handle(error, start: start) }
    }
    func clear() { generation = UUID(); lastShopSync = nil; financialEntries = nil; deliveryRecord = nil; authorized = false; shop = nil; review = nil; pending = nil; draft = .init(); notice = nil; editing = false; acknowledged = false; delivery = .none }
    private func handle(_ error: Error, start: UUID) async {
        guard start == generation else { return }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _): clear(); await onAccessEnded()
        case .service(status: 409, code: "reservation_review_required", correlationID: _, retryAfter: _):
            review = nil; acknowledged = false
            notice = ht("Review the usable amount, ingredient match and existing reservations before setting food aside.")
        case .service(let status, _, _, _) where status == 409:
            review = nil; acknowledged = false; notice = ht("The shop or shopper authority changed. Refresh the current shop and review again.")
        case .cancelled: break
        default: notice = ht("The shared shop change is not confirmed. Keep the pending action and retry it unchanged.")
        }
    }
}
