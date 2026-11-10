import Foundation
import SwiftUI
import HouseholdClient

enum ShopperChoice: String, CaseIterable, Identifiable {
    case add, link, deferRequest = "defer", dismiss, handled
    var id: String { rawValue }
    var title: String {
        switch self { case .add: return ht("Add packs to this shop"); case .link: return ht("Link an existing line")
        case .deferRequest: return ht("Save for next shop"); case .dismiss: return ht("Do not include"); case .handled: return ht("Mark handled") }
    }
}
enum ShopperDelivery: Equatable {
    case none, waiting, needsReview, confirmed(ShopperReceipt)
}

/// Owns one authorized shopper's transient projection. A saved operation contains only its reviewed command, never a cached inbox projection.
@MainActor final class HouseholdInboxModel: ObservableObject {
    @Published private(set) var authorized = true
    @Published private(set) var busy = false
    @Published private(set) var shop: ShopperShop?
    @Published private(set) var requests: [OwnRequest] = []
    @Published private(set) var deferredRequests: [DeferredRequest] = []
    @Published private(set) var deferredPage: DeferredRequestsPage?
    private var deferredLoad = UUID()
    @Published private(set) var nextCursor: String?
    @Published private(set) var selected: OwnRequest?
    @Published private(set) var preview: ShopperPreview?
    @Published private(set) var requestFood: SharedRequestFoodContext?
    private var reviewedDecision: SharedRequestDecisionReview?
    private var reviewedFood: SharedDemandReview?
    @Published private(set) var delivery: ShopperDelivery = .none
    @Published private(set) var notice: String?
    @Published private(set) var pending: PendingOperation?
    @Published private(set) var reviewedCurrentFacts = false
    @Published private(set) var packSelection: HouseholdRequestPackSelection?
    // Text-field blur and control refreshes may commit their existing value.
    // Only an actual fact change invalidates an in-flight or reviewed decision.
    @Published var choice: ShopperChoice = .deferRequest { didSet { if oldValue != choice { invalidatePreview() } } }
    @Published var lineItem = "" { didSet { if oldValue != lineItem { invalidatePreview() } } }
    @Published var packs = 1 { didSet { if oldValue != packs { invalidatePreview() } } }
    @Published var price = "" { didSet { if oldValue != price { invalidatePreview() } } }
    @Published var feeEligible = true { didSet { if oldValue != feeEligible { invalidatePreview() } } }
    @Published var linkedLineID = "" { didSet { if oldValue != linkedLineID { invalidatePreview() } } }
    @Published var promote = false { didSet { if oldValue != promote { invalidatePreview(preservePackSelection: true) } } }
    @Published var clarification = ""
    @Published var acceptOverage = false { didSet { if oldValue != acceptOverage { cancelRequestFood() } } }
    @Published var acceptUnknown = false { didSet { if oldValue != acceptUnknown { cancelRequestFood() } } }
    let householdID: String
    let memberID: String
    let shopID: String
    private let bootstrap: HouseholdBootstrap
    private let service: HouseholdService
    private let outbox: OperationOutbox
    private let onAccessEnded: @MainActor () async -> Void
    private var generation = UUID()
    private var draftGeneration = UUID()
    private var attempts = 0
    @Published private(set) var retryAfter = Date.distantPast

    init(bootstrap: HouseholdBootstrap, service: HouseholdService, outbox: OperationOutbox,
         onAccessEnded: @escaping @MainActor () async -> Void) {
        self.bootstrap = bootstrap; householdID = bootstrap.household.id; memberID = bootstrap.memberId
        shopID = bootstrap.shopId ?? ""; self.service = service; self.outbox = outbox; self.onAccessEnded = onAccessEnded
        authorized = bootstrap.role == "shopper" && bootstrap.shopId != nil
    }
    var supportsPurchaseConfirmation: Bool {
        authorized && bootstrap.grantId == nil && bootstrap.capabilities.contains("request_purchase_confirmation")
    }
    func purchaseMatches(placed: SharedDeliveryPage) -> [RequestPurchaseMatch] {
        guard supportsPurchaseConfirmation, let shop, shop.shopId == shopID else { return [] }
        return requests.compactMap { RequestPurchaseMatch(request: $0, shop: shop, placed: placed) }
    }
    func purchaseMatch(_ requestID: String, placed: SharedDeliveryPage) -> RequestPurchaseMatch? {
        guard supportsPurchaseConfirmation, let shop, shop.shopId == shopID,
              let request = requests.first(where: { $0.id == requestID }) else { return nil }
        return RequestPurchaseMatch(request: request, shop: shop, placed: placed)
    }
    func confirmPurchase(_ match: RequestPurchaseMatch, outcome: ConfirmedRequestPurchase?, placed: SharedDeliveryPage) async {
        guard purchaseMatch(match.request.id, placed: placed) == match, match.request.purchaseOutcome != outcome else { return }
        await enqueue(kind: "request.confirmPurchase", base: match.base, body: match.body(outcome: outcome))
    }
    var supportsDeferredRequests: Bool {
        authorized && bootstrap.grantId == nil && bootstrap.capabilities.contains("deferred_requests")
    }
    var canReviewDeferred: Bool { supportsDeferredRequests && shop?.phase == "draft" }
    func forgetDeferred() {
        deferredLoad = UUID()
        deferredPage = nil
        deferredRequests = []
    }
    func loadDeferred(more: Bool = false) async {
        guard canReviewDeferred, !busy, pending == nil else { return }
        let cursor = more ? deferredPage?.nextCursor : nil
        if more && cursor == nil { return }
        if !more { forgetDeferred() }
        busy = true
        defer { busy = false }
        let scope = generation, load = deferredLoad
        do {
            let page = try await service.deferredRequests(shopID: shopID, after: cursor)
            guard generation == scope, deferredLoad == load, canReviewDeferred else { return }
            guard page.shopRevision == shop?.shopRevision, page.authorityEpoch == shop?.authorityEpoch else {
                throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil)
            }
            guard Set(deferredRequests.map(\.id)).isDisjoint(with: page.requests.map(\.id)) else {
                throw ClientError.invalidResponse
            }
            deferredRequests += page.requests
            deferredPage = page
        } catch {
            guard generation == scope, deferredLoad == load else { return }
            forgetDeferred()
            await handle(error, start: scope)
        }
    }
    func carryForReview(_ request: DeferredRequest) async {
        guard canReviewDeferred, !busy, pending == nil, deferredRequests.contains(request), let page = deferredPage,
              shop?.shopRevision == page.shopRevision, shop?.authorityEpoch == page.authorityEpoch else { return }
        forgetDeferred()
        await enqueue(kind: "request.carry", base: .init(shopRevision: page.shopRevision,
            authorityEpoch: page.authorityEpoch, requestRevision: request.requestRevision),
            body: ["requestId": .string(request.id.uuidString.lowercased()),
                   "sourceShopId": .string(request.sourceShopId.uuidString.lowercased()),
                   "sourceAuthorityEpoch": .integer(request.sourceAuthorityEpoch)])
    }
    var availableChoices: [ShopperChoice] {
        guard let selected, let shop else { return [] }
        if selected.carriedForward == true { return [] }
        if selected.status == "deferred" { return shop.phase == "draft" ? [.add, .link] : [] }
        guard selected.ownActionAllowed else { return [] }
        return shop.phase == "draft" ? ShopperChoice.allCases : [.deferRequest, .dismiss, .handled]
    }
    var canApply: Bool {
        guard authorized, !busy, pending == nil, requestFood == nil, let preview, let expiry = serviceDate(preview.expiresAt), expiry > Date() else { return false }
        return (!preview.requiresOverageAcceptance || acceptOverage) && (!preview.requiresUnknownAcceptance || acceptUnknown)
    }
    /// A receipt alone is insufficient: the original inbox row must have refreshed
    /// under the same shopper authority before its decision sheet can return.
    var confirmedDecisionRequestID: String? {
        guard authorized, !busy, pending == nil, case .confirmed(let receipt) = delivery,
              receipt.kind == "request.apply", receipt.shopId == shopID, receipt.shopRevision > 0,
              ["added", "deferred", "dismissed", "handled"].contains(receipt.disposition),
              let shop, shop.shopId == shopID, shop.authorityEpoch == receipt.authorityEpoch,
              shop.shopRevision >= receipt.shopRevision,
              let requestID = receipt.requestId, let revision = receipt.requestRevision, revision > 0,
              let request = requests.first(where: { $0.id == requestID && $0.shopId == shopID }),
              request.revision >= revision,
              ["added", "deferred", "dismissed", "handled", "withdrawn"].contains(request.status),
              request.revision > revision || request.status == receipt.disposition else { return nil }
        return requestID
    }
    func hasPossibleDuplicate(_ request: OwnRequest) -> Bool {
        requests.filter { $0.originalItem.localizedCaseInsensitiveCompare(request.originalItem) == .orderedSame }.count > 1
    }
    func load(more: Bool = false) async {
        guard authorized, !busy else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            if more {
                guard let cursor = nextCursor else { return }
                let page = try await service.shopperInbox(shopID: shopID, cursor: cursor)
                guard start == generation else { return }
                guard page.requests.allSatisfy({ $0.shopId == shopID }) else { throw ClientError.invalidResponse }
                for request in page.requests { requests.removeAll { $0.id == request.id }; requests.append(request) }
                nextCursor = page.nextCursor
            } else {
                try await refreshFacts(start: start)
                guard start == generation else { return }
                if pending == nil {
                    let saved = try await outbox.operations()
                    guard start == generation else { return }
                    if let operation = saved.first(where: { $0.householdID == householdID && $0.memberID == memberID && $0.targetsShop(shopID) }) {
                        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
                        pending = operation
                        let matches = await service.matches(operation, memberID: memberID)
                        guard start == generation else { return }
                        let permitted = (envelope.kind != "request.confirmPurchase" || supportsPurchaseConfirmation) &&
                            (envelope.kind != "request.carry" || supportsDeferredRequests)
                        delivery = matches && permitted && envelope.shopId == shopID ? .waiting : .needsReview
                        notice = ht("An earlier decision is waiting for confirmation. Review the current requests before retrying or clearing it.")
                    }
                }
                reviewedCurrentFacts = pending != nil
            }
        } catch {
            if case .confirmed(let receipt) = delivery, receipt.kind == "request.apply" {
                await handleConfirmedRefresh(error, start: start)
            } else { await handle(error, start: start) }
        }
    }
    private func refreshFacts(start: UUID) async throws {
        let value = try await service.shopperShop(shopID: shopID)
        var page = try await service.shopperInbox(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        guard value.shopId == shopID, page.requests.allSatisfy({ $0.shopId == shopID }) else { throw ClientError.invalidResponse }
        let target: String?
        if case .confirmed(let receipt) = delivery, receipt.kind == "request.apply", receipt.shopId == shopID {
            target = receipt.requestId
        } else { target = nil }
        var refreshed = page.requests
        var seenIDs = Set(refreshed.map(\.id))
        var seenCursors = Set<String>()
        guard seenIDs.count == refreshed.count else { throw ClientError.invalidResponse }
        // Keep the original request reachable even when it was on a later page.
        // Publish no partial result while locating its durable outcome.
        while let target, !refreshed.contains(where: { $0.id == target }), let cursor = page.nextCursor {
            guard seenCursors.insert(cursor).inserted else { throw ClientError.invalidResponse }
            page = try await service.shopperInbox(shopID: shopID, cursor: cursor)
            guard start == generation else { throw ClientError.cancelled }
            guard page.requests.allSatisfy({ $0.shopId == shopID && seenIDs.insert($0.id).inserted }) else {
                throw ClientError.invalidResponse
            }
            refreshed += page.requests
        }
        if target != nil {
            let latest = try await service.shopperShop(shopID: shopID)
            guard start == generation else { throw ClientError.cancelled }
            guard latest.shopId == value.shopId, latest.shopRevision == value.shopRevision,
                  latest.authorityEpoch == value.authorityEpoch else {
                throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil)
            }
        }
        forgetDeferred()
        shop = value; requests = refreshed; nextCursor = page.nextCursor; invalidatePreview()
        if let selected { self.selected = requests.first { $0.id == selected.id } }
    }
    func select(_ request: OwnRequest) {
        guard authorized, !busy, pending == nil, request.shopId == shopID else { return }
        selected = request; lineItem = request.originalItem; packs = 1; price = ""; linkedLineID = ""
        feeEligible = true; promote = false; clarification = ""; notice = nil; delivery = .none
        choice = availableChoices.contains(.deferRequest) ? .deferRequest : (availableChoices.first ?? .deferRequest)
        invalidatePreview()
    }
    func invalidatePreview(preservePackSelection: Bool = false) {
        draftGeneration = UUID(); preview = nil; reviewedDecision = nil; cancelRequestFood(); acceptOverage = false; acceptUnknown = false
        if !preservePackSelection { packSelection = nil }
    }
    func cancelReview() { guard pending == nil else { return }; invalidatePreview(); selected = nil; clarification = "" }
    func review() async {
        guard authorized, !busy, pending == nil, let selected, let shop, availableChoices.contains(choice) else { return }
        invalidatePreview(preservePackSelection: true)
        busy = true; notice = nil; defer { busy = false }; let start = generation; let draft = draftGeneration
        do {
            let decision = try makeDecision()
            let value = try await service.shopperPreview(shopID: shopID, requestID: selected.id,
                base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, requestRevision: selected.revision), decision: decision)
            guard start == generation, draft == draftGeneration else { return }
            guard value.choice == decision.choice, value.shopRevision == shop.shopRevision,
                  value.authorityEpoch == shop.authorityEpoch, value.requestRevision == selected.revision else { throw ClientError.invalidResponse }
            reviewedDecision = .init(request: selected, shop: shop, decision: decision, preview: value)
            preview = value
        } catch { await handle(error, start: start) }
    }
    var packReviewScope: HouseholdRequestPackScope? {
        guard authorized, pending == nil, let selected, let shop, bootstrap.role == "shopper", bootstrap.grantId == nil else { return nil }
        return HouseholdRequestPackScope(generation: generation, bootstrap: bootstrap, request: selected, shop: shop)
    }
    @discardableResult func usePackSelection(_ selection: HouseholdRequestPackSelection) -> Bool {
        guard !busy, availableChoices.contains(.add), let scope = packReviewScope else { return false }
        do {
            try selection.validate(scope: scope)
            choice = .add; lineItem = selection.line.originalItem; packs = selection.line.packs
            if let cents = selection.line.unitPriceMinor { price = "\(cents / 100).\(String(format: "%02d", cents % 100))" }
            else { price = "" }
            feeEligible = selection.line.feeEligible
            packSelection = selection; notice = nil
            return true
        } catch { notice = ht("The request or shop changed. Reopen the pack review before using this choice."); return false }
    }
    private func makeDecision() throws -> ShopperDecision {
        if (choice == .add || choice == .link), selected?.route == "next", !promote { throw ShopperInputError.promotion }
        switch choice {
        case .add:
            if let packSelection {
                guard let scope = packReviewScope else { throw ShopperInputError.preview }
                try packSelection.validate(scope: scope)
                return .add(line: packSelection.line, promote: promote, reviewedPackEvidence: try packSelection.decisionEvidence())
            }
            let item = lineItem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty, item.count <= 240, (1...10_000).contains(packs) else { throw ShopperInputError.line }
            let amount = try Self.priceMinor(price)
            return .add(line: .init(originalItem: item, packs: packs, unitPriceMinor: amount, feeEligible: feeEligible), promote: promote)
        case .link:
            guard shop?.lines.contains(where: { $0.id == linkedLineID }) == true else { throw ShopperInputError.link }
            return .link(lineID: linkedLineID, promote: promote)
        case .deferRequest: return .deferRequest
        case .dismiss: return .dismiss
        case .handled: return .handled
        }
    }
    static func priceMinor(_ value: String) throws -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard text.range(of: "^[0-9]+([.,][0-9]{1,2})?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              decimal >= 0, decimal <= 10_000_000 else { throw ShopperInputError.price }
        return NSDecimalNumber(decimal: decimal * 100).intValue
    }
    func apply() async {
        guard canApply, let selected, let preview else { notice = ht("Review a current preview and the required acknowledgments before applying."); return }
        if preview.choice == "add" || preview.choice == "link" {
            guard let reviewedDecision, reviewedDecision.request == selected, reviewedDecision.preview == preview,
                  reviewedDecision.shop == shop else { invalidatePreview(); return }
            let start = generation, draft = draftGeneration, overage = acceptOverage, unknown = acceptUnknown
            busy = true
            do {
                guard let id = UUID(uuidString: shopID) else { throw ClientError.configuration }
                let page = try await service.sharedDemand(shopID: id)
                guard start == generation, draft == draftGeneration, authorized, pending == nil,
                      self.reviewedDecision == reviewedDecision, self.preview == preview,
                      self.selected == selected, self.shop == reviewedDecision.shop,
                      acceptOverage == overage, acceptUnknown == unknown,
                      page.shopRevision == preview.shopRevision, page.authorityEpoch == preview.authorityEpoch,
                      (serviceDate(preview.expiresAt) ?? .distantPast) > Date() else { throw ClientError.cancelled }
                if page.status == .reviewRequired {
                    invalidatePreview(preservePackSelection: true)
                    notice = SharedDemandCopy.text("Review the surviving food facts in Food quantities first, then reopen this request.")
                    busy = false; return
                }
                if page.status == .enabled {
                    requestFood = try .init(reviewed: reviewedDecision, page: page, acceptOverage: overage, acceptUnknown: unknown)
                    busy = false; return
                }
                // Only an explicit validated legacy status takes the existing
                // decision path. Missing/failed demand reads never become legacy.
                guard page.status == .legacy else { throw ClientError.invalidResponse }
                busy = false
            } catch {
                busy = false
                guard start == generation else { return }
                if draft == draftGeneration {
                    invalidatePreview(preservePackSelection: true); await handle(error, start: start)
                    if authorized, (error as? ClientError) == .cancelled { notice = SharedDemandCopy.text("The shop changed. Refresh and review again.") }
                }
                return
            }
        }
        await enqueue(kind: "request.apply", base: preview.base,
                      body: ["requestId": .string(selected.id), "previewId": .string(preview.previewId),
                             "acceptOverage": .bool(acceptOverage), "acceptUnknown": .bool(acceptUnknown)], previewID: preview.previewId)
    }
    func sendClarification() async {
        guard authorized, !busy, pending == nil, let selected, selected.ownActionAllowed, let shop else { return }
        let question = clarification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 300 else { notice = ht("Enter a question up to 300 characters."); return }
        await enqueue(kind: "request.clarify", base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, requestRevision: selected.revision),
                      body: ["requestId": .string(selected.id), "question": .string(question)])
    }
    private func enqueue(kind: String, base: CommandBase, body: [String: JSONValue], previewID: String? = nil) async {
        guard authorized, !busy, pending == nil else { return }
        busy = true; notice = nil; defer { busy = false }; let start = generation
        do {
            let window = try await service.replayWindow()
            guard start == generation else { return }
            if let previewID {
                guard let preview, preview.previewId == previewID, let expiry = serviceDate(preview.expiresAt), expiry > Date() else {
                    throw ShopperInputError.preview
                }
            }
            let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shopID, kind: kind, base: base, body: body), bootstrap: bootstrap)
            guard start == generation else { return }
            try await outbox.append(operation)
            guard start == generation else { return }
            pending = operation; attempts = 0; reviewedCurrentFacts = false; delivery = .waiting
            await deliver(operation, start: start)
        } catch { await handle(error, start: start) }
    }
    func retry() async {
        guard authorized, !busy, let pending, delivery == .waiting else { return }
        guard Date() >= retryAfter else { notice = ht("Wait before retrying the same decision."); return }
        busy = true; defer { busy = false }; await deliver(pending, start: generation)
    }
    private func deliver(_ operation: PendingOperation, start: UUID) async {
        attempts += 1
        do {
            let receipt: ShopperReceipt
            if operation.sharedDemandBinding != nil { receipt = try await service.executeSharedDemand(operation) }
            else { receipt = try await service.executeShopper(operation) }
            guard start == generation else { return }
            guard receipt.shopId == shopID else { throw ClientError.invalidResponse }
            // The valid receipt supersedes a prior delivery error. Cleanup and
            // refresh below may still report their own actionable warning.
            notice = nil
            delivery = .confirmed(receipt); pending = nil; selected = nil; clarification = ""; invalidatePreview()
            do { try await outbox.remove(operation.id) }
            catch { notice = ht("The decision was confirmed. Local retry cleanup needs another attempt.") }
            guard start == generation else { return }
            shop = nil; requests = []; nextCursor = nil
            do { try await refreshFacts(start: start) }
            catch { await handleConfirmedRefresh(error, start: start) }
        } catch {
            guard start == generation else { return }
            if pending != nil {
                if let failure = error as? ClientError, let delay = RetryPolicy().delay(attempt: attempts, error: failure) {
                    retryAfter = Date().addingTimeInterval(delay)
                } else { delivery = .needsReview; reviewedCurrentFacts = false }
            }
            await handle(error, start: start)
        }
    }
    func clearPendingAfterReview() async {
        guard authorized, !busy, reviewedCurrentFacts, let pending else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            try await outbox.remove(pending.id)
            guard start == generation else { return }
            self.pending = nil; delivery = .none; attempts = 0; notice = nil; selected = nil; invalidatePreview()
        } catch { await handle(error, start: start) }
    }
    func clear() {
        forgetDeferred()
        generation = UUID(); authorized = false; shop = nil; requests = []; selected = nil; nextCursor = nil
        pending = nil; delivery = .none; notice = nil; clarification = ""; lineItem = ""; price = ""; linkedLineID = ""; invalidatePreview()
    }
    private func handleConfirmedRefresh(_ error: Error, start: UUID) async {
        guard start == generation else { return }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
            await handle(error, start: start)
        case .cancelled: break
        default: notice = ht("The decision was confirmed. Refresh requests to see the latest state.")
        }
    }
    private func handle(_ error: Error, start: UUID) async {
        guard start == generation else { return }
        if let input = error as? ShopperInputError { notice = input.message; return }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
            clear(); await onAccessEnded()
        case .service(let status, let code, _, _) where status == 409:
            invalidatePreview()
            notice = code == "stale_quote" ? ht("The saved quote has expired. Refresh its prices before adding or linking a request.") : ht("The shop, request, or assigned shopper changed. Refresh and review before creating a new decision.")
        case .cancelled: break
        default: notice = ht("The service could not confirm this decision. Retry the pending decision to avoid a duplicate.")
        }
    }
}
extension HouseholdInboxModel: SharedDemandFlowAccess {
    var foodShop: ShopperShop? { shop }
    var foodEditorID: UUID? { requestFood?.id }
    var foodPending: Bool { pending != nil }
    var canReadFood: Bool {
        authorized && bootstrap.role == "shopper" && bootstrap.grantId == nil &&
        bootstrap.capabilities.contains("shopper_commands") && shop?.shopId == shopID && shop?.phase == "draft"
    }
    func cancelRequestFood() { requestFood = nil; reviewedFood = nil }
    private func currentFood(_ context: SharedRequestFoodContext) -> Bool {
        canReadFood && requestFood == context && reviewedDecision == context.reviewed &&
        selected == context.reviewed.request && shop == context.reviewed.shop && preview == context.reviewed.preview &&
        acceptOverage == context.action.acceptOverage && acceptUnknown == context.action.acceptUnknown &&
        (serviceDate(context.reviewed.preview.expiresAt) ?? .distantPast) > Date() &&
        (serviceDate(context.reviewed.shop.quote.expiresAt) ?? .distantPast) > Date()
    }
    func readFood() async throws -> SharedDemandPage {
        guard !busy, pending == nil, let context = requestFood, currentFood(context), let id = UUID(uuidString: shopID) else { throw ClientError.cancelled }
        let start = generation; busy = true; defer { busy = false }
        do {
            let currentShop = try await service.shopperShop(shopID: shopID)
            let page = try await service.sharedDemand(shopID: id)
            guard start == generation, currentFood(context), currentShop == context.reviewed.shop, page == context.page else { throw ClientError.cancelled }
            reviewedFood = nil; return page
        } catch { await handle(error, start: start); throw error }
    }
    func previewFood(_ request: SharedDemandPreviewRequest) async throws -> SharedDemandReview {
        guard !busy, pending == nil, let context = requestFood, currentFood(context),
              request.action == .request(context.action), request.mode == .change,
              request.base == .init(shopRevision: context.page.shopRevision, authorityEpoch: context.page.authorityEpoch, graphRevision: context.page.graph?.revision ?? 0),
              let id = UUID(uuidString: shopID) else { throw ClientError.cancelled }
        let start = generation; busy = true; defer { busy = false }; reviewedFood = nil
        do {
            let result = try await service.previewSharedDemand(shopID: id, request: request)
            guard start == generation, currentFood(context), pending == nil else { throw ClientError.cancelled }
            reviewedFood = result; return result
        } catch { await handle(error, start: start); throw error }
    }
    func applyFood(_ review: SharedDemandReview) async throws {
        guard !busy, pending == nil, let context = requestFood, currentFood(context), reviewedFood == review,
              review.request.action == .request(context.action) else { throw ClientError.cancelled }
        let start = generation; busy = true; defer { busy = false }
        do {
            let operation = try await service.prepareSharedDemandApply(review)
            guard start == generation, currentFood(context), reviewedFood == review, pending == nil else { throw ClientError.cancelled }
            try await outbox.append(operation)
            guard start == generation else { throw ClientError.cancelled }
            pending = operation; attempts = 0; reviewedCurrentFacts = false; delivery = .waiting; reviewedFood = nil
            await deliver(operation, start: start)
        } catch { await handle(error, start: start); throw error }
    }
}

private enum ShopperInputError: Error {
    case price, line, link, promotion, preview
    var message: String {
        switch self {
        case .price: return ht("Enter a price with up to two decimal places, or leave it blank if unknown.")
        case .line: return ht("Enter an item and a whole number of packs from 1 to 10,000.")
        case .link: return ht("Choose an existing line before reviewing this link.")
        case .promotion: return ht("Confirm moving this next-shop request into the current shop.")
        case .preview: return ht("This preview expired or changed. Review a fresh preview before applying.")
        }
    }
}
func serviceDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
