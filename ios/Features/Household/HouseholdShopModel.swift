import Foundation
import SwiftUI
import HouseholdClient
import CoreDomain

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
    @Published private(set) var recoveryRecord: SharedRecoveryPage? {
        didSet { if recoveryRecord != oldValue { reviewedRecovery = nil } }
    }
    private var reviewedRecovery: (page: SharedRecoveryPage, intent: SharedRecoveryIntent, preview: SharedRecoveryPreview)?
    private var recoveryRead = UUID()
    private var reviewedRecoveryOperation: String?
    @Published private(set) var pantryRecord: SharedPantryPage? {
        didSet {
            if recoveryRecord?.base.pantryRevision != pantryRecord?.pantryRevision { recoveryRecord = nil }
        }
    }
    @Published private(set) var deliveryRecord: SharedDeliveryPage? {
        didSet { if oldValue != deliveryRecord { pantryRecord = nil; reviewedObservation = nil; reviewedPantryOperation = nil } }
    }
    private var reviewedObservation: (edit: SharedPantryEdit, pantry: SharedPantryPage, preview: SharedPantryObservationPreview)?
    private var observationRead = UUID()
    private var reviewedPantryOperation: String?
    @Published private(set) var financialRecord: ShopperFinancialRecord? {
        didSet { if financialRecord == nil { financialSummary = nil } }
    }
    private(set) var financialSummary: SettlementSummary?
    @Published private(set) var financialRetry: ShopperFinancialIntent?
    private let financialStore: HistoryPendingStore?
    private let financialSubject: String?
    var financialEntries: [ShopperFinancialEntry]? { financialRecord?.entries }
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
    private var reviewedAmendmentOperation: String?
    private var retryAfter = Date.distantPast
    private var reviewedCookRecipient: (page: SharedDeliveryPage, occurrence: UUID, label: String, sendId: UUID?)?
    private var baselineReadID = UUID()
    private var pendingMarkOccurrence: UUID?
    private var reviewedCookOperation: String?
    init(scope: HouseholdBootstrap, service: HouseholdService, outbox: OperationOutbox,
         financialStore: HistoryPendingStore? = nil, financialSubject: String? = nil,
         onConfirmed: @escaping @MainActor () async -> Void, onAccessEnded: @escaping @MainActor () async -> Void) {
        self.financialStore = financialStore; self.financialSubject = financialSubject
        self.scope = scope; self.service = service; self.outbox = outbox; self.onConfirmed = onConfirmed; self.onAccessEnded = onAccessEnded
        householdID = scope.household.id; memberID = scope.memberId
    }
    var canCreate: Bool { authorized && !requiresRefresh && scope.grantId == nil && scope.role == "organizer" && scope.capabilities.contains("household_admin") && scope.shopId == nil && scope.selectionRequired != true }
    var canManage: Bool { authorized && !requiresRefresh && scope.grantId == nil && scope.role == "shopper" && scope.capabilities.contains("shopper_commands") && scope.shopId != nil }
    var canReadConfirmedOrder: Bool { canManage && scope.capabilities.contains("confirmed_order") }
    var canReadDelivery: Bool { canManage && scope.capabilities.contains("delivery_evidence") }
    var canReadPantry: Bool { canReadDelivery && scope.capabilities.contains("pantry_lots") }
    var canReadMealRecovery: Bool { canReadPantry && scope.capabilities.contains("meal_recovery") }
    var canReadCookCopies: Bool { canReadDelivery && scope.capabilities.contains("cook_copies") }
    var canReviewCookCorrection: Bool { canReadCookCopies && scope.capabilities.contains("cook_corrections") }
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
            financialRecord = nil; financialRetry = nil; deliveryRecord = nil; review = nil; acknowledged = false
            reviewedCookRecipient = nil; pendingMarkOccurrence = nil; reviewedCookOperation = nil; reviewedAmendmentOperation = nil
            if scope.shopId != value.shopId, pendingCookCopy || pendingPantry || pendingMealRecovery || pendingAmendment || pendingDelivery { pending = nil; delivery = .none; reviewedCurrentFacts = false }
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
            if pendingAmendment {
                if !canReadConfirmedOrder { delivery = .needsReview }
                reviewedCurrentFacts = !canReadConfirmedOrder || pending?.id == reviewedAmendmentOperation
            } else if pendingMealRecovery {
                if !canReadMealRecovery { delivery = .needsReview }
                reviewedCurrentFacts = !canReadMealRecovery || reviewedRecoveryOperation == pending?.id
            } else if pendingPantry {
                if !canReadPantry { delivery = .needsReview }
                reviewedCurrentFacts = !canReadPantry || pending?.id == reviewedPantryOperation
            } else if pendingCookCopy {
                let canReconcile = canRetryCookCopy
                if !canReconcile { delivery = .needsReview }
                reviewedCurrentFacts = !canReconcile || reviewedCookOperation == pending?.id
            } else {
                if pendingDelivery && !canReadDelivery { delivery = .needsReview }
                reviewedCurrentFacts = pending != nil && (!pendingDelivery || !canReadDelivery)
            }
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
                financialRecord = nil; financialRetry = nil
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
    func confirmedOrder() async throws -> SharedConfirmedOrder {
        guard canReadConfirmedOrder, let shop, let id = UUID(uuidString: shop.shopId),
              ["placed", "closed"].contains(shop.phase) else { throw ClientError.accessEnded }
        let start = generation, actor = scope, operation = pending
        func sameReview() -> Bool {
            start == generation && scope == actor && self.shop == shop && canReadConfirmedOrder
        }
        func markPendingReviewed() {
            guard sameReview(), let operation, pending == operation, pendingAmendment,
                  operation.householdID == actor.household.id, operation.memberID == actor.memberId,
                  pendingEnvelope?.shopId == shop.shopId else { return }
            reviewedAmendmentOperation = operation.id; reviewedCurrentFacts = true
        }
        do {
            let page = try await service.confirmedOrder(shopID: id)
            guard sameReview() else { throw ClientError.cancelled }
            guard page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch,
                  page.placedRevision == shop.placedRevision else { throw ClientError.service(status: 409, code: "stale_order", correlationID: nil, retryAfter: nil) }
            markPendingReviewed()
            return page
        } catch {
            // An authoritative erasure fence is a terminal reviewed outcome, not an
            // endlessly retryable failure. Only this exact actor/shop's pending action
            // may be explicitly cleared after that notice is shown.
            if case ClientError.service(status: 409, code: "order_evidence_removed", correlationID: _, retryAfter: _) = error,
               sameReview() {
                markPendingReviewed()
                if pending == operation, reviewedCurrentFacts {
                    delivery = .needsReview
                    notice = OrderAmendmentCopy.text("The order evidence was removed. Review this notice before clearing the saved local retry.")
                }
            }
            throw error
        }
    }
    func confirmOrder(_ confirmation: SharedOrderConfirmation, reviewed page: SharedConfirmedOrder) async -> Bool {
        guard canReadConfirmedOrder, !busy, pending == nil, let shop,
              UUID(uuidString: shop.shopId) == page.shopId, ["placed", "closed"].contains(shop.phase),
              page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch,
              page.placedRevision == shop.placedRevision else { return false }
        busy = true; let start = generation, actor = scope
        defer { busy = false }
        do {
            let fields = try confirmation.body(reviewed: page)
            let window = try await service.replayWindow()
            guard start == generation, scope == actor, self.shop == shop, canReadConfirmedOrder else { return false }
            let envelope = CommandEnvelope(replayWindow: window.id, shopId: shop.shopId, kind: "amendment.recordResponse",
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: fields)
            try await queueAndDeliver(envelope, start: start)
            guard start == generation, scope.shopId == shop.shopId else { return false }
            if case .confirmed = delivery { return true }
            return false
        } catch { await handle(error, start: start); return false }
    }
    func loadDelivery() async {
        guard canReadDelivery, let shop, shop.placedRevision != nil, !busy else { return }
        let start = generation, actor = scope, operation = pending
        busy = true; defer { busy = false }
        do {
            let page = try await service.deliveryEvidence(shopID: shop.shopId)
            guard start == generation, scope == actor, canReadDelivery, scope.shopId == shop.shopId, self.shop == shop,
                  UUID(uuidString: shop.shopId) == page.shopId else { return }
            guard page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch,
                  page.placedRevision == shop.placedRevision else {
                throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
            }
            deliveryRecord = page; notice = nil
            if let operation, pending == operation, pendingDelivery,
               operation.householdID == actor.household.id, operation.memberID == actor.memberId,
               pendingEnvelope?.shopId == shop.shopId { reviewedCurrentFacts = true }
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
    private var pendingEnvelope: CommandEnvelope? {
        pending.flatMap { try? JSONDecoder().decode(CommandEnvelope.self, from: $0.bytes) }
    }
    private var pendingAmendment: Bool { pendingEnvelope?.kind == "amendment.recordResponse" }
    var pendingMealRecovery: Bool { pendingEnvelope?.kind == "mealRecovery.apply" }
    var pendingDelivery: Bool { pendingEnvelope?.kind.hasPrefix("delivery.") == true }
    private var pendingPantry: Bool { pendingEnvelope?.kind.hasPrefix("pantry.") == true }
    private var pendingCookUsesPantry: Bool { pendingEnvelope?.kind == "cookCopy.save" && pendingEnvelope?.body["pantryRevision"] != nil }
    private var canRetryCookCopy: Bool {
        canReadCookCopies && (pendingEnvelope?.body["factIndex"] == nil || canReviewCookCorrection) && (!pendingCookUsesPantry || canReadPantry) && (pendingEnvelope?.body["recoveryRevision"] == nil || canReadMealRecovery)
    }
    private var pendingCookCopy: Bool { pendingEnvelope?.kind.hasPrefix("cookCopy.") == true }

    private func refreshMealRecovery(shop: ShopperShop, start: UUID) async throws {
        let facts = try await service.mealRecoveryFacts(shopID: shop.shopId)
        guard generation == start, self.shop == shop, scope.shopId == shop.shopId, canReadMealRecovery else { throw ClientError.cancelled }
        guard facts.page.placedRevision == shop.placedRevision, facts.page.base.authorityEpoch == shop.authorityEpoch,
              facts.page.base.shopRevision == shop.shopRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        deliveryRecord = facts.delivery
        pantryRecord = facts.pantry
        recoveryRecord = facts.page
        if pendingMealRecovery { reviewedRecoveryOperation = pending?.id; reviewedCurrentFacts = true }
    }

    func loadMealRecovery() async {
        guard canReadMealRecovery, !busy, let shop, shop.placedRevision != nil else { return }
        let start = generation
        busy = true; defer { busy = false }
        do {
            try await refreshMealRecovery(shop: shop, start: start)
            notice = nil
        } catch {
            guard start == generation, self.shop == shop else { return }
            recoveryRecord = nil
            await handlePantryRead(error, start: start)
        }
    }

    func effectiveCoverage(reviewed page: SharedRecoveryPage) async throws -> SharedRecoveryCoverage {
        guard canReadMealRecovery, recoveryRecord == page else { throw ClientError.cancelled }
        let start = generation
        do {
            let result = try await service.effectiveCoverage(reviewed: page)
            guard !Task.isCancelled, start == generation, canReadMealRecovery, recoveryRecord == page else { throw ClientError.cancelled }
            return result
        } catch {
            if recoveryRecord == page { await handlePantryRead(error, start: start) }
            throw error
        }
    }

    func previewMealRecovery(_ intent: SharedRecoveryIntent, reviewed page: SharedRecoveryPage) async throws -> SharedRecoveryPreview {
        guard canReadMealRecovery, shop?.phase == "placed", !busy, pending == nil, recoveryRecord == page else { throw ClientError.cancelled }
        let start = generation, read = UUID()
        recoveryRead = read; reviewedRecovery = nil
        do {
            let result = try await service.previewMealRecovery(intent, reviewed: page)
            guard !Task.isCancelled, start == generation, recoveryRead == read, canReadMealRecovery, !busy,
                  pending == nil, recoveryRecord == page else { throw ClientError.cancelled }
            reviewedRecovery = (page, intent, result)
            return result
        } catch {
            if recoveryRecord == page { await handlePantryRead(error, start: start) }
            throw error
        }
    }

    func applyMealRecovery(_ preview: SharedRecoveryPreview, intent: SharedRecoveryIntent, reviewed page: SharedRecoveryPage) async -> Bool {
        guard let checked = reviewedRecovery, checked.page == page, checked.intent == intent, checked.preview == preview,
              canReadMealRecovery, recoveryRecord == page, let evidence = deliveryRecord, let pantry = pantryRecord else { return false }
        return await saveReviewedChange(kind: "mealRecovery.apply", reviewed: evidence, reviewedPantry: pantry, reviewedRecovery: page,
                                        expires: serviceDate(preview.expiresAt)) { try intent.commandBody(reviewed: page, preview: preview) }
    }

    func saveCookCopy(text: String, language: String, facts: SharedCookFactIndex? = nil, meal: SharedRecoveryMeal, reviewed page: SharedRecoveryPage) async -> Bool {
        guard canReadCookCopies, canReadMealRecovery, recoveryRecord == page, let pantry = pantryRecord, let evidence = deliveryRecord,
              page.meals.contains(meal), let sealed = evidence.meals?.first(where: { $0.id == meal.id && $0.revision == meal.sourceMealRevision }) else { return false }
        let edit = SharedCookCopyEdit.save(text: text, language: language, occurrence: sealed, facts: canReviewCookCorrection ? facts : nil)
        return await saveReviewedChange(kind: edit.kind, reviewed: evidence, reviewedPantry: pantry, reviewedRecovery: page) {
            try edit.body(reviewed: evidence, pantry: pantry, recovery: page)
        }
    }

    func loadPantry(reviewed delivery: SharedDeliveryPage) async {
        guard !busy, canReadPantry, deliveryRecord == delivery else { return }
        busy = true; defer { busy = false }
        let start = generation
        do {
            let record = try await service.pantryLots(reviewed: delivery)
            guard start == generation, canReadPantry, deliveryRecord == delivery else { return }
            pantryRecord = record; reviewedObservation = nil; notice = nil
            if pendingPantry { reviewedPantryOperation = pending?.id; reviewedCurrentFacts = true }
        } catch {
            guard start == generation, deliveryRecord == delivery else { return }
            pantryRecord = nil; reviewedObservation = nil
            await handlePantryRead(error, start: start)
        }
    }
    func foodCoverage(reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage) async throws -> SharedFoodCoverage {
        guard canReadPantry, deliveryRecord == delivery, pantryRecord == pantry else { throw ClientError.cancelled }
        let start = generation
        do {
            let result = try await service.foodCoverage(reviewed: pantry, delivery: delivery)
            guard start == generation, canReadPantry, deliveryRecord == delivery, pantryRecord == pantry else { throw ClientError.cancelled }
            return result
        } catch {
            if deliveryRecord == delivery && pantryRecord == pantry { await handlePantryRead(error, start: start) }
            throw error
        }
    }
    func previewPantryObservation(_ edit: SharedPantryEdit, reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage) async throws -> SharedPantryObservationPreview {
        guard canReadPantry, shop?.phase == "placed", !busy, pending == nil, deliveryRecord == delivery, pantryRecord == pantry else { throw ClientError.cancelled }
        let start = generation, read = UUID()
        observationRead = read; reviewedObservation = nil
        do {
            let preview = try await service.previewPantryObservation(edit, reviewed: pantry, delivery: delivery)
            guard !Task.isCancelled, start == generation, read == observationRead, canReadPantry,
                  pending == nil, deliveryRecord == delivery, pantryRecord == pantry else { throw ClientError.cancelled }
            reviewedObservation = (edit, pantry, preview)
            return preview
        } catch {
            if deliveryRecord == delivery && pantryRecord == pantry { await handlePantryRead(error, start: start) }
            throw error
        }
    }
    private func handlePantryRead(_ error: Error, start: UUID) async {
        guard start == generation else { return }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
            await handle(error, start: start)
        case .cancelled: break
        default: notice = ht("Refresh deliveries and review the current record.")
        }
    }
    func savePantry(_ edit: SharedPantryEdit, reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage,
                    preview: SharedPantryObservationPreview? = nil) async -> Bool {
        if case .observe = edit {
            guard let review = reviewedObservation, review.edit == edit, review.pantry == pantry, review.preview == preview else { return false }
        } else if preview != nil { return false }
        return await saveReviewedChange(kind: edit.kind, reviewed: delivery, reviewedPantry: pantry) {
            var body = try edit.body(reviewed: pantry, delivery: delivery)
            if let preview { body["previewDigest"] = .string(preview.previewDigest) }
            return body
        }
    }
    func cookCopies(occurrence: SharedMealOccurrence, reviewed page: SharedDeliveryPage) async throws -> [SharedCookCopy] {
        guard canReadCookCopies, deliveryRecord == page else { throw ClientError.cancelled }
        let start = generation
        do {
            let copies = try await service.cookCopies(occurrence: occurrence, reviewed: page)
            guard !Task.isCancelled, start == generation, canReadCookCopies, deliveryRecord == page else { throw ClientError.cancelled }
            if let envelope = pendingEnvelope, envelope.shopId == scope.shopId {
                if envelope.kind == "cookCopy.save", envelope.body["occurrenceId"] == .string(occurrence.id.uuidString.lowercased()) {
                    reviewedCookOperation = pending?.id; reviewedCurrentFacts = true
                } else if envelope.kind == "cookCopy.markSent", copies.contains(where: { envelope.body["copyId"] == .string($0.id.uuidString.lowercased()) }) {
                    pendingMarkOccurrence = occurrence.id
                }
            }
            return copies
        } catch {
            if deliveryRecord == page { await handleCookCopyRead(error, start: start) }
            throw error
        }
    }
    func pendingCookRecipient(for occurrence: SharedMealOccurrence) -> String? {
        guard pendingMarkOccurrence == occurrence.id, let envelope = pendingEnvelope, envelope.kind == "cookCopy.markSent",
              case .string(let label) = envelope.body["recipient"] else { return nil }
        return label
    }
    func cookCopyBaseline(recipient: String, occurrence: SharedMealOccurrence, reviewed page: SharedDeliveryPage) async throws -> SharedCookCopyBaseline? {
        guard canReadCookCopies, deliveryRecord == page else { throw ClientError.cancelled }
        reviewedCookRecipient = nil
        let start = generation, readID = UUID()
        baselineReadID = readID
        do {
            let baseline = try await service.cookCopyBaseline(recipient: recipient, occurrence: occurrence, reviewed: page)
            guard !Task.isCancelled, start == generation, canReadCookCopies, deliveryRecord == page else { throw ClientError.cancelled }
            guard readID == baselineReadID else { throw ClientError.cancelled }
            let label = try SharedCookCopyEdit.recipientLabel(recipient)
            reviewedCookRecipient = (page, occurrence.id, label, baseline?.send.sendId)
            if pendingCookRecipient(for: occurrence)?.utf8.elementsEqual(label.utf8) == true {
                reviewedCookOperation = pending?.id; reviewedCurrentFacts = true
            }
            return baseline
        } catch {
            if deliveryRecord == page { await handleCookCopyRead(error, start: start) }
            throw error
        }
    }
    func reviewedCookCorrection(_ copy: SharedCookCopy, recipient: String, baseline: SharedCookCopyBaseline?,
                                destinationConfirmed: Bool, paid: Bool, occurrence: SharedMealOccurrence,
                                reviewed page: SharedDeliveryPage) async throws -> HandoffCorrection {
        let start = generation
        do {
            if canReviewCookCorrection, paid, destinationConfirmed, let baseline {
                do {
                    let result = try await cookCorrection(copy: copy, baseline: baseline, recipient: recipient,
                        destinationConfirmed: destinationConfirmed, occurrence: occurrence, reviewed: page)
                    if case .changes = result { return result }
                } catch ClientError.service(status: 403, code: "membership_inactive", correlationID: _, retryAfter: _) {
                    // The shopper can still review the complete current wording on Free.
                }
            }
            try await checkFullCookCorrection(copy, recipient: recipient, previousSendId: baseline?.send.sendId,
                                              occurrence: occurrence, reviewed: page)
            return .full(copy.text)
        } catch {
            switch error as? ClientError {
            case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
                await handle(error, start: start)
            default: break
            }
            throw error
        }
    }

    private func checkFullCookCorrection(_ copy: SharedCookCopy, recipient: String, previousSendId: UUID?, occurrence: SharedMealOccurrence, reviewed page: SharedDeliveryPage) async throws {
        guard canReadCookCopies, deliveryRecord == page,
              copy.shopRevision == page.shopRevision, copy.authorityEpoch == page.authorityEpoch,
              copy.supplyRevision == page.supplyRevision, copy.recoveryRevision == nil || copy.recoveryRevision == page.recoveryRevision else { throw ClientError.cancelled }
        let start = generation
        let current = try await service.deliveryEvidence(shopID: page.shopId.uuidString.lowercased())
        guard current == page, start == generation, canReadCookCopies, deliveryRecord == page else { throw ClientError.cancelled }
        if let revision = copy.pantryRevision {
            guard canReadPantry else { throw ClientError.cancelled }
            let pantry = try await service.pantryLots(reviewed: page)
            guard pantry.pantryRevision == revision, start == generation, canReadPantry else { throw ClientError.cancelled }
        }
        let copies = try await cookCopies(occurrence: occurrence, reviewed: page)
        let baseline = try await service.cookCopyBaseline(recipient: recipient, occurrence: occurrence, reviewed: page)
        guard baseline?.send.sendId == previousSendId, start == generation, canReadCookCopies, deliveryRecord == page, copies.first == copy else { throw ClientError.cancelled }
    }

    private func cookCorrection(copy: SharedCookCopy, baseline: SharedCookCopyBaseline, recipient: String, destinationConfirmed: Bool,
                        occurrence: SharedMealOccurrence, reviewed page: SharedDeliveryPage) async throws -> HandoffCorrection {
        func authorized() -> Bool {
            guard canReviewCookCorrection, deliveryRecord == page, let review = reviewedCookRecipient else { return false }
            return review.page == page && review.occurrence == occurrence.id && review.label.utf8.elementsEqual(recipient.utf8)
                && review.sendId == baseline.send.sendId
        }
        guard authorized() else { throw ClientError.cancelled }
        let start = generation
        let facts = try await service.cookCorrection(copy: copy, baseline: baseline, recipient: recipient, destinationConfirmed: destinationConfirmed,
                                                     occurrence: occurrence, reviewed: page)
        guard !Task.isCancelled, start == generation, authorized() else { throw ClientError.cancelled }
        guard let index = facts.currentFacts, let priorIndex = facts.previousFacts,
              copy.language == baseline.copy.language else { return .full(copy.text) }

        // Time-sensitive usable food can change even between equal revision numbers.
        let source: SharedCookCoverage
        switch index.source {
        case .recovered:
            guard canReadMealRecovery else { throw ClientError.cancelled }
            let record = try await service.mealRecoveryFacts(shopID: page.shopId.uuidString.lowercased())
            guard authorized(), canReadMealRecovery, record.delivery == page, record.pantry.pantryRevision == copy.pantryRevision,
                  let meal = record.page.meals.first(where: { $0.id == occurrence.id }),
                  let origin = record.page.mealSources.first(where: { $0.occurrenceId == meal.id }),
                  meal.revisionId == (copy.revisionId ?? origin.sealedRevisionId) else { throw ClientError.cancelled }
            source = .recovered(record.page, try await service.effectiveCoverage(reviewed: record.page), meal)
            guard canReadMealRecovery else { throw ClientError.cancelled }
        case .food:
            guard canReadPantry else { throw ClientError.cancelled }
            let pantry = try await service.pantryLots(reviewed: page)
            guard authorized(), canReadPantry, pantry.pantryRevision == copy.pantryRevision else { throw ClientError.cancelled }
            source = .food(pantry, try await service.foodCoverage(reviewed: pantry, delivery: page))
            guard canReadPantry else { throw ClientError.cancelled }
        case .delivery:
            guard copy.pantryRevision == nil else { throw ClientError.cancelled }
            source = .delivery(try await coverage(reviewed: page))
        }
        guard !Task.isCancelled, start == generation, authorized(),
              let fresh = SharedDeliveryCookDraft.instruction(page: page, report: source, occurrence: occurrence,
                                                             language: copy.language == "es" ? "es-US" : "en-US") else { throw ClientError.cancelled }
        let result = try fresh.correction(current: copy, previous: baseline.copy, currentIndex: index,
                                          previousIndex: priorIndex, destinationConfirmed: destinationConfirmed)
        // Coverage can require multiple requests. Fence a recipient, seat or source
        // change while those requests were in flight before releasing the comparison.
        let confirmed = try await service.cookCorrection(copy: copy, baseline: baseline, recipient: recipient,
            destinationConfirmed: destinationConfirmed, occurrence: occurrence, reviewed: page)
        guard confirmed == facts, !Task.isCancelled, start == generation, authorized() else { throw ClientError.cancelled }
        return result
    }

    private func handleCookCopyRead(_ error: Error, start: UUID) async {
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded: await handle(error, start: start)
        default: break
        }
    }
    func saveCookCopy(text: String, language: String, facts: SharedCookFactIndex? = nil, occurrence: SharedMealOccurrence, reviewed page: SharedDeliveryPage, pantry: SharedPantryPage? = nil) async -> Bool {
        let edit = SharedCookCopyEdit.save(text: text, language: language, occurrence: occurrence, facts: canReviewCookCorrection ? facts : nil)
        return await saveReviewedChange(kind: edit.kind, reviewed: page, reviewedPantry: pantry) { try edit.body(reviewed: page, pantry: pantry) }
    }
    func markCookCopySent(_ copy: SharedCookCopy, recipient: String, previousSendId: UUID?, reviewed page: SharedDeliveryPage) async -> Bool {
        guard let label = try? SharedCookCopyEdit.recipientLabel(recipient), let baseline = reviewedCookRecipient, baseline.page == page, baseline.occurrence == copy.occurrenceId,
              baseline.label.utf8.elementsEqual(label.utf8), baseline.sendId == previousSendId else { return false }
        let edit = SharedCookCopyEdit.markSent(copy: copy, recipient: recipient, previousSendId: previousSendId)
        return await saveReviewedChange(kind: edit.kind, reviewed: page) { try edit.body(reviewed: page) }
    }
    func saveDelivery(_ edit: SharedDeliveryEdit, reviewed page: SharedDeliveryPage) async -> Bool {
        await saveReviewedChange(kind: edit.kind, reviewed: page) { try edit.body(reviewed: page) }
    }
    private func saveReviewedChange(kind: String, reviewed page: SharedDeliveryPage, reviewedPantry: SharedPantryPage? = nil, reviewedRecovery: SharedRecoveryPage? = nil, expires: Date? = nil, body: () throws -> [String: JSONValue]) async -> Bool {
        let cookCopy = kind.hasPrefix("cookCopy."), pantryEdit = kind.hasPrefix("pantry.")
        let recovering = kind == "mealRecovery.apply"
        let physicalCorrection = ["delivery.register", "delivery.arrival", "delivery.usable", "delivery.match", "delivery.reserve"].contains(kind)
        if let reviewedRecovery, !canReadMealRecovery || recoveryRecord != reviewedRecovery { return false }
        if recovering, (expires ?? .distantPast) <= Date() { return false }
        if let reviewedPantry, !canReadPantry || pantryRecord != reviewedPantry { return false }
        guard canReadDelivery, !busy, pending == nil, let shop, scope.shopId == shop.shopId,
              cookCopy ? (canReadCookCopies && ["placed", "closed"].contains(shop.phase)) :
                  (shop.phase == "placed" || (physicalCorrection && shop.phase == "closed")),
              page == deliveryRecord, UUID(uuidString: shop.shopId) == page.shopId, page.shopRevision == shop.shopRevision,
              page.authorityEpoch == shop.authorityEpoch, page.placedRevision == shop.placedRevision else { return false }
        busy = true; let start = generation, actorScope = scope
        defer { busy = false }
        do {
            let fields = try body()
            let window = try await service.replayWindow()
            guard start == generation, scope == actorScope, self.shop == shop, deliveryRecord == page, canReadDelivery,
                  reviewedPantry == nil || pantryRecord == reviewedPantry,
                  reviewedRecovery == nil || canReadMealRecovery && recoveryRecord == reviewedRecovery,
                  !recovering || (expires ?? .distantPast) > Date() else { return false }
            let envelope = CommandEnvelope(replayWindow: window.id, shopId: shop.shopId, kind: kind,
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: fields)
            try await queueAndDeliver(envelope, start: start)
            guard start == generation, scope.shopId == shop.shopId else { return false }
            if case .confirmed(let receipt) = delivery {
                if recovering {
                    return !requiresRefresh && recoveryRecord?.meals.first(where: { $0.id == receipt.occurrenceId })?.revisionId == receipt.revisionId
                }
                if pantryEdit { return !requiresRefresh && (pantryRecord?.pantryRevision ?? -1) >= (receipt.pantryRevision ?? 0) }
                if !cookCopy { deliveryRecord = nil }
                return true
            }
            return !recovering && !cookCopy && !pantryEdit && delivery == .waiting && pending != nil
        } catch { await handle(error, start: start); return false }
    }
    func loadFinancialEntries() async {
        guard canManage, let id = scope.shopId, !busy else { return }
        busy = true
        let start = generation
        defer { busy = false }
        do { try await readFinancial(shopID: id, start: start) }
        catch { await handle(error, start: start) }
    }
    private func readFinancial(shopID: String, start: UUID) async throws {
        financialRecord = nil; financialRetry = nil
        let record = try await service.shopperFinancialRecord(shopID: shopID)
        let stored = try await financialStore?.read().financialChanges?.first {
            $0.subject == financialSubject && $0.householdID == householdID && $0.memberID == memberID && $0.shopID == record.shopID
        }
        guard generation == start, scope.shopId == shopID, canManage else { throw ClientError.cancelled }
        if let stored, stored.version.authorityEpoch != record.version.authorityEpoch, let financialStore {
            // A transfer invalidates the previous assignment even if this adult later returns.
            let epoch = await financialStore.epoch()
            try await financialStore.finishFinancial(stored, expectedEpoch: epoch)
        }
        guard generation == start, scope.shopId == shopID, canManage else { throw ClientError.cancelled }
        financialRetry = stored?.version.authorityEpoch == record.version.authorityEpoch ? stored : nil
        financialSummary = try SettlementLedger.summary(of: record.entries.map { try $0.settlementEntry() })
        financialRecord = record; notice = nil
    }
    func writeFinancial(_ action: ShopperFinancialAction, reviewed record: ShopperFinancialRecord) async -> Bool {
        guard canManage, !busy, financialRetry == nil, financialRecord == record, let financialStore,
              let shop, UUID(uuidString: shop.shopId) == record.shopID, shop.placedRevision != nil,
              shop.shopRevision == record.version.shopRevision, shop.authorityEpoch == record.version.authorityEpoch,
              shop.phase == "placed" || (shop.phase == "closed" && action != .close) else { return false }
        busy = true; defer { busy = false }
        let start = generation, epoch = await financialStore.epoch()
        do {
            let intent = try await service.prepareFinancial(action, reviewed: record)
            guard generation == start, scope.shopId == shop.shopId, canManage, intent.subject == financialSubject else { throw ClientError.cancelled }
            try await financialStore.stageFinancial(intent, expectedEpoch: epoch)
            guard generation == start, scope.shopId == shop.shopId, canManage else { throw ClientError.cancelled }
            financialRetry = intent
            return try await deliverFinancial(intent, store: financialStore, epoch: epoch, start: start)
        } catch { await handle(error, start: start); return false }
    }
    func retryFinancial() async -> Bool {
        guard canManage, !busy, let intent = financialRetry, let financialStore, let shopID = scope.shopId,
              UUID(uuidString: shopID) == intent.shopID, financialRecord?.version.authorityEpoch == intent.version.authorityEpoch else { return false }
        busy = true; defer { busy = false }
        let start = generation, epoch = await financialStore.epoch()
        do { return try await deliverFinancial(intent, store: financialStore, epoch: epoch, start: start) }
        catch { await handle(error, start: start); return false }
    }
    private func deliverFinancial(_ intent: ShopperFinancialIntent, store: HistoryPendingStore, epoch: UUID, start: UUID) async throws -> Bool {
        let id = intent.shopID.uuidString.lowercased()
        do { try await service.executeFinancial(intent) }
        catch ClientError.service(let status, let code, _, _) where status == 422 || (status == 409 && code == "stale_source") {
            try await store.finishFinancial(intent, expectedEpoch: epoch)
            guard generation == start, scope.shopId == id else { throw ClientError.cancelled }
            financialRetry = nil; financialRecord = nil
            try await refreshFacts(start: start)
            try await readFinancial(shopID: id, start: start)
            notice = status == 422 ? pTr("Enter a valid amount and evidence ID. Credits must link to an original posted charge.") : ht("The shop or shopper authority changed. Refresh the current shop and review again.")
            return false
        }
        try await store.finishFinancial(intent, expectedEpoch: epoch)
        guard generation == start, scope.shopId == id else { throw ClientError.cancelled }
        financialRetry = nil; financialRecord = nil
        try await refreshFacts(start: start)
        try await readFinancial(shopID: id, start: start)
        return true
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
            if canCreate || (creatingAnother && canStartAnother) {
                review = .init(shopID: UUID().uuidString.lowercased(), kind: "shop.create",
                               base: .init(shopRevision: 0, authorityEpoch: 0), candidate: enteredCandidate)
            } else if canManage, let shop, shop.phase == "draft" {
                let candidate = try ShopperShopCandidate(quote: enteredCandidate.quote, lines: enteredCandidate.lines,
                                                         reviewedStoreBasisRevision: shop.storeBasisRevision)
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
                              (meal.day == nil || sharedMealDate(meal.day) != nil) else { throw ClientError.configuration }
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
        pendingMarkOccurrence = nil; reviewedCookOperation = nil; reviewedPantryOperation = nil; reviewedAmendmentOperation = nil
        if envelope.kind == "cookCopy.markSent" { reviewedCookRecipient = nil; baselineReadID = UUID() }
        await deliver(operation, start: start)
    }
    func retry() async {
        guard authorized, !busy, let pending, delivery == .waiting else { return }
        if pendingEnvelope?.kind == "amendment.recordResponse" && (!canReadConfirmedOrder || pendingEnvelope?.shopId != scope.shopId) { return }
        if pendingDelivery && (!canReadDelivery || pendingEnvelope?.shopId != scope.shopId) { return }
        if pendingMealRecovery && (!canReadMealRecovery || pendingEnvelope?.shopId != scope.shopId) { return }
        if pendingCookCopy && (!canRetryCookCopy || pendingEnvelope?.shopId != scope.shopId) { return }
        if pendingPantry && (!canReadPantry || pendingEnvelope?.shopId != scope.shopId) { return }
        guard Date() >= retryAfter, attempts < 5 else { notice = ht("Wait before retrying, or review this action after several failed attempts."); return }
        busy = true; defer { busy = false }; await deliver(pending, start: generation)
    }
    private func deliver(_ operation: PendingOperation, start: UUID) async {
        attempts += 1
        do {
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
            let receipt = try await service.executeSharedShop(operation); guard start == generation else { return }
            let cookCopy = envelope.kind.hasPrefix("cookCopy."), pantryEdit = envelope.kind.hasPrefix("pantry.")
            let recovering = envelope.kind == "mealRecovery.apply"
            if envelope.kind == "amendment.recordResponse", pending != operation || !canReadConfirmedOrder || scope.shopId != envelope.shopId { return }
            if envelope.kind.hasPrefix("delivery."), pending != operation || !canReadDelivery || scope.shopId != envelope.shopId { return }
            if recovering, pending != operation || !canReadMealRecovery || scope.shopId != envelope.shopId { return }
            if pantryEdit, pending != operation || !canReadPantry || scope.shopId != envelope.shopId { return }
            if cookCopy, pending != operation || !canReadCookCopies || scope.shopId != envelope.shopId { return }
            guard receipt.shopId == envelope.shopId, receipt.kind == envelope.kind else { throw ClientError.invalidResponse }
            delivery = .confirmed(receipt); pending = nil; editing = false; creatingAnother = false; review = nil; acknowledged = false
            // A copy receipt leaves every reviewed shop and delivery revision intact.
            requiresRefresh = !cookCopy && !pantryEdit && !recovering
            if cookCopy || pantryEdit || recovering { notice = nil }
            if recovering { recoveryRecord = nil; reviewedRecovery = nil }
            do { try await outbox.remove(operation.id) } catch { notice = ht("The shared shop change was confirmed. Local retry cleanup needs another attempt.") }
            guard start == generation else { return }
            do {
                if envelope.kind == "shop.create", scope.canSelectShop == true, let id = UUID(uuidString: receipt.shopId) {
                    _ = try await service.selectShop(id)
                }
                try await refreshFacts(start: start)
                if recovering {
                    guard let current = shop, current.shopId == envelope.shopId, canReadMealRecovery else { throw ClientError.cancelled }
                    try await refreshMealRecovery(shop: current, start: start)
                    guard let revision = receipt.recoveryRevision, let page = recoveryRecord, page.base.recoveryRevision >= revision else {
                        throw ClientError.invalidResponse
                    }
                } else if pantryEdit {
                    guard canReadPantry, scope.shopId == envelope.shopId, let current = shop else { throw ClientError.cancelled }
                    let evidence = try await service.deliveryEvidence(shopID: envelope.shopId)
                    let record = try await service.pantryLots(reviewed: evidence)
                    guard start == generation, canReadPantry, shop == current, scope.shopId == envelope.shopId,
                          current.placedRevision == evidence.placedRevision, current.authorityEpoch == evidence.authorityEpoch,
                          current.shopRevision == evidence.shopRevision, record.pantryRevision >= (receipt.pantryRevision ?? 0) else { throw ClientError.cancelled }
                    deliveryRecord = evidence; pantryRecord = record; reviewedObservation = nil
                }
                await onConfirmed()
            }
            catch {
                guard start == generation else { return }
                switch error as? ClientError {
                case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _): await handle(error, start: start)
                case .cancelled: break
                default:
                    requiresRefresh = true
                    notice = ht("The shared shop change was confirmed. Refresh the household to see the latest state.")
                }
            }
        } catch {
            guard start == generation else { return }
            guard pending == operation else { return }
            if let error = error as? ClientError, let delay = RetryPolicy().delay(attempt: attempts, error: error) { retryAfter = Date().addingTimeInterval(delay) }
            else { delivery = .needsReview; reviewedCurrentFacts = false }
            await handle(error, start: start)
        }
    }
    func clearPendingAfterReview() async {
        guard authorized, !busy, reviewedCurrentFacts, let pending else { return }
        if pendingDelivery, pendingEnvelope?.shopId != scope.shopId { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            try await outbox.remove(pending.id); guard start == generation else { return }
            reviewedCookOperation = nil; pendingMarkOccurrence = nil; reviewedAmendmentOperation = nil; reviewedCurrentFacts = false
            self.pending = nil; delivery = .none; review = nil; acknowledged = false; attempts = 0
        } catch { await handle(error, start: start) }
    }
    func clear() {
        reviewedAmendmentOperation = nil; reviewedCurrentFacts = false
        reviewedCookRecipient = nil; pendingMarkOccurrence = nil; reviewedCookOperation = nil
        recoveryRecord = nil; reviewedRecovery = nil; reviewedRecoveryOperation = nil
        generation = UUID(); lastShopSync = nil; financialRecord = nil; financialRetry = nil; deliveryRecord = nil
        authorized = false; shop = nil; review = nil; pending = nil; draft = .init()
        notice = nil; editing = false; acknowledged = false; delivery = .none
    }
    private func handle(_ error: Error, start: UUID) async {
        guard start == generation else { return }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _): clear(); await onAccessEnded()
        case .service(status: 409, code: "match_exclusion_conflict", correlationID: _, retryAfter: _):
            review = nil; acknowledged = false
            notice = ht("This food conflicts with an exclusion for this ingredient. The match was not saved. Review the food and ingredient exclusions before trying another match.")
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
