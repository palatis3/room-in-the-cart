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

/// Owns only one authorized shopper's transient projection. No prices are saved in the outbox.
@MainActor final class HouseholdInboxModel: ObservableObject {
    @Published private(set) var authorized = true
    @Published private(set) var busy = false
    @Published private(set) var shop: ShopperShop?
    @Published private(set) var requests: [OwnRequest] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var selected: OwnRequest?
    @Published private(set) var preview: ShopperPreview?
    @Published private(set) var delivery: ShopperDelivery = .none
    @Published private(set) var notice: String?
    @Published private(set) var pending: PendingOperation?
    @Published private(set) var reviewedCurrentFacts = false
    @Published var choice: ShopperChoice = .deferRequest { didSet { invalidatePreview() } }
    @Published var lineItem = "" { didSet { invalidatePreview() } }
    @Published var packs = 1 { didSet { invalidatePreview() } }
    @Published var price = "" { didSet { invalidatePreview() } }
    @Published var feeEligible = true { didSet { invalidatePreview() } }
    @Published var linkedLineID = "" { didSet { invalidatePreview() } }
    @Published var promote = false { didSet { invalidatePreview() } }
    @Published var clarification = ""
    @Published var acceptOverage = false
    @Published var acceptUnknown = false
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
    private var retryAfter = Date.distantPast

    init(bootstrap: HouseholdBootstrap, service: HouseholdService, outbox: OperationOutbox,
         onAccessEnded: @escaping @MainActor () async -> Void) {
        self.bootstrap = bootstrap; householdID = bootstrap.household.id; memberID = bootstrap.memberId
        shopID = bootstrap.shopId ?? ""; self.service = service; self.outbox = outbox; self.onAccessEnded = onAccessEnded
        authorized = bootstrap.role == "shopper" && bootstrap.shopId != nil
    }
    var availableChoices: [ShopperChoice] {
        guard let selected, let shop else { return [] }
        if selected.status == "deferred" { return shop.phase == "draft" ? [.add, .link] : [] }
        guard selected.ownActionAllowed else { return [] }
        return shop.phase == "draft" ? ShopperChoice.allCases : [.deferRequest, .dismiss, .handled]
    }
    var canApply: Bool {
        guard authorized, !busy, pending == nil, let preview, let expiry = serviceDate(preview.expiresAt), expiry > Date() else { return false }
        return (!preview.requiresOverageAcceptance || acceptOverage) && (!preview.requiresUnknownAcceptance || acceptUnknown)
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
                for request in page.requests { requests.removeAll { $0.id == request.id }; requests.append(request) }
                nextCursor = page.nextCursor
            } else {
                try await refreshFacts(start: start)
                guard start == generation else { return }
                if pending == nil {
                    let saved = try await outbox.operations()
                    guard start == generation else { return }
                    if let operation = saved.first(where: { $0.householdID == householdID && $0.memberID == memberID }) {
                        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
                        pending = operation
                        let matches = await service.matches(operation, memberID: memberID)
                        guard start == generation else { return }
                        delivery = matches && envelope.shopId == shopID ? .waiting : .needsReview
                        notice = ht("An earlier decision is waiting for confirmation. Review the current requests before retrying or clearing it.")
                    }
                }
                reviewedCurrentFacts = pending != nil
            }
        } catch { await handle(error, start: start) }
    }
    private func refreshFacts(start: UUID) async throws {
        let value = try await service.shopperShop(shopID: shopID)
        let page = try await service.shopperInbox(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        guard value.shopId == shopID, page.requests.allSatisfy({ $0.shopId == shopID }) else { throw ClientError.invalidResponse }
        shop = value; requests = page.requests; nextCursor = page.nextCursor; invalidatePreview()
        if let selected { self.selected = requests.first { $0.id == selected.id } }
    }
    func select(_ request: OwnRequest) {
        guard authorized, !busy, pending == nil, request.shopId == shopID else { return }
        selected = request; lineItem = request.originalItem; packs = 1; price = ""; linkedLineID = ""
        feeEligible = true; promote = false; clarification = ""; notice = nil; delivery = .none
        choice = availableChoices.contains(.deferRequest) ? .deferRequest : (availableChoices.first ?? .deferRequest)
        invalidatePreview()
    }
    func invalidatePreview() {
        draftGeneration = UUID(); preview = nil; acceptOverage = false; acceptUnknown = false
    }
    func cancelReview() { guard pending == nil else { return }; invalidatePreview(); selected = nil; clarification = "" }
    func review() async {
        guard authorized, !busy, pending == nil, let selected, let shop, availableChoices.contains(choice) else { return }
        busy = true; notice = nil; defer { busy = false }; let start = generation; let draft = draftGeneration
        do {
            let decision = try makeDecision()
            let value = try await service.shopperPreview(shopID: shopID, requestID: selected.id,
                base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, requestRevision: selected.revision), decision: decision)
            guard start == generation, draft == draftGeneration else { return }
            guard value.choice == decision.choice, value.shopRevision == shop.shopRevision,
                  value.authorityEpoch == shop.authorityEpoch, value.requestRevision == selected.revision else { throw ClientError.invalidResponse }
            preview = value
        } catch { await handle(error, start: start) }
    }
    private func makeDecision() throws -> ShopperDecision {
        if (choice == .add || choice == .link), selected?.route == "next", !promote { throw ShopperInputError.promotion }
        switch choice {
        case .add:
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
            let receipt = try await service.executeShopper(operation)
            guard start == generation else { return }
            guard receipt.shopId == shopID else { throw ClientError.invalidResponse }
            delivery = .confirmed(receipt); pending = nil; selected = nil; clarification = ""; invalidatePreview()
            do { try await outbox.remove(operation.id) }
            catch { notice = ht("The decision was confirmed. Local retry cleanup needs another attempt.") }
            guard start == generation else { return }
            shop = nil; requests = []; nextCursor = nil
            do { try await refreshFacts(start: start) }
            catch {
                guard start == generation else { return }
                switch error as? ClientError {
                case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
                    await handle(error, start: start)
                case .cancelled: break
                default: notice = ht("The decision was confirmed. Refresh requests to see the latest state.")
                }
            }
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
        generation = UUID(); authorized = false; shop = nil; requests = []; selected = nil; nextCursor = nil
        pending = nil; delivery = .none; notice = nil; clarification = ""; lineItem = ""; price = ""; linkedLineID = ""; invalidatePreview()
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
