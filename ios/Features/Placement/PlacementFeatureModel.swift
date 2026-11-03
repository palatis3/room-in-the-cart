import Foundation
import Combine
import HouseholdClient

struct PlacementRuntimeScope: Equatable, Sendable {
    let generation: UUID; let subject: String; let householdID: String; let memberID: String
    let currentShopID: String?; let authorityStamp: String; let canManage: Bool
    init(generation: UUID, subject: String, householdID: String, memberID: String, currentShopID: String?, authorityStamp: String = "", canManage: Bool = false) {
        self.generation = generation; self.subject = subject; self.householdID = householdID; self.memberID = memberID
        self.currentShopID = currentShopID; self.authorityStamp = authorityStamp; self.canManage = canManage
    }
}
protocol PlacementServing: Sendable {
    func placementShop(shopID: String) async throws -> ShopperShop
    func preparePlacementSnapshot(reviewed: ShopperShop) async throws -> PlacementPreparedSnapshot
    func executePlacementReport(_ intent: PlacementReportIntent) async throws -> PlacementReporterReceipt
    func placementReportStatus(_ intent: PlacementReportIntent) async throws -> PlacementReporterStatus?
    func pendingPlacementReports(shopID: String, cursor: String?) async throws -> PlacementReportPage
    func placementReport(shopID: String, reportID: String) async throws -> PlacementReportDetail
    func preparePlacementReview(page: PlacementReportPage, report: PlacementPendingReport, choice: PlacementReviewChoice) async throws -> PlacementReviewIntent
    func executePlacementReview(_ intent: PlacementReviewIntent) async throws -> PlacementReviewReceipt
}
extension HouseholdService: PlacementServing {}

enum PlacementReview: Equatable {
    case capture(ShopperShop)
    case report(PlacementReportIntent)
    case reconcile(page: PlacementReportPage, report: PlacementPendingReport, choice: PlacementReviewChoice)
}
enum PlacementDate {
    static func string(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = f.date(from: value) { return value }; f.formatOptions = [.withInternetDateTime]; return f.date(from: value)
    }
}

@MainActor final class PlacementFeatureModel: ObservableObject {
    @Published private(set) var currentShop: ShopperShop?
    @Published private(set) var reportPage: PlacementReportPage?
    @Published private(set) var saved: [PlacementLocalRecord] = []
    @Published private(set) var selected: PlacementLocalRecord?
    @Published private(set) var pendingReview: PlacementLocalReview?
    @Published private(set) var reviewed: PlacementReview?
    @Published var approved = false
    @Published var occurredAt = Date() { didSet { if case .report = reviewed { cancelReview() } } }
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    private let service: any PlacementServing
    private let store: any PlacementPersisting
    private let runtime: () -> PlacementRuntimeScope?
    private let onAccessEnded: () async -> Void
    private let clock: () -> Date
    private var scope: PlacementRuntimeScope?
    private var generation = UUID()
    private var storeEpoch: UUID?
    private var storedReviews: [PlacementLocalReview] = []
    private var seenCursors = Set<String>()
    private var reportReceiptInMemory: (id: String, receipt: PlacementReporterReceipt)?
    private var reviewReceiptInMemory: (id: String, receipt: PlacementReviewReceipt)?

    init(service: any PlacementServing, store: any PlacementPersisting, runtime: @escaping () -> PlacementRuntimeScope?,
         onAccessEnded: @escaping () async -> Void = {}, clock: @escaping () -> Date = Date.init) {
        self.service = service; self.store = store; self.runtime = runtime; self.onAccessEnded = onAccessEnded; self.clock = clock
    }
    var authorized: Bool { scope != nil && scope == runtime() }
    var canManage: Bool { authorized && scope?.canManage == true && scope?.currentShopID != nil }
    var reports: [PlacementPendingReport] { canManage ? reportPage?.reports ?? [] : [] }
    var reportCursor: String? { canManage ? reportPage?.nextCursor : nil }
    var canCapture: Bool { canManage && !busy && storeEpoch != nil && currentShop.map { ["draft", "frozen"].contains($0.phase) } == true }
    var canReport: Bool { authorized && !busy && storeEpoch != nil && selected != nil && selected?.report == nil }
    var canApply: Bool { authorized && !busy && storeEpoch != nil && approved && reviewed != nil }
    var reportWindowExpired: Bool { selected.map { PlacementDate.date($0.capture.replayWindow.expiresAt).map { $0 <= clock() } ?? true } ?? true }
    var reviewWindowExpired: Bool { pendingReview.map { PlacementDate.date($0.intent.replayWindow.expiresAt).map { $0 <= clock() } ?? true } ?? true }
    var canRetryReport: Bool {
        authorized && !busy && selected?.report != nil && selected?.receipt == nil && selected?.status == nil &&
        (!reportWindowExpired || reportReceiptInMemory?.id == selected?.id)
    }
    var canRetryReconciliation: Bool {
        canManage && !busy && pendingReview != nil && pendingReview?.retired == false && pendingReview?.receipt == nil &&
        (pendingReview?.status == nil || pendingReview?.status?.report.state == "pending_reconciliation") &&
        (!reviewWindowExpired || reviewReceiptInMemory?.id == pendingReview?.id)
    }
    func cancelReview() { reviewed = nil; approved = false }
    func invalidate() {
        generation = UUID(); scope = nil; storeEpoch = nil; currentShop = nil; reportPage = nil; saved = []; selected = nil
        pendingReview = nil; storedReviews = []; cancelReview(); notice = nil; occurredAt = clock(); seenCursors = []
        reportReceiptInMemory = nil; reviewReceiptInMemory = nil
    }
    func enforceRuntime() { if scope != nil && !authorized { invalidate() } }
    private func live(_ start: UUID) -> Bool { start == generation && authorized }
    private func owns(_ capture: PlacementPreparedSnapshot) -> Bool {
        capture.subject == scope?.subject && capture.householdID == scope?.householdID && capture.memberID == scope?.memberID
    }
    private func owns(_ intent: PlacementReviewIntent) -> Bool {
        intent.subject == scope?.subject && intent.householdID == scope?.householdID && intent.memberID == scope?.memberID
    }
    /// No network call: a native actor may reopen only their original evidence after leaving the retailer app offline.
    func load() async {
        guard !busy, let context = runtime() else { return }
        invalidate(); scope = context; busy = true; defer { busy = false }; let start = generation
        do {
            let epoch = await store.epoch(), state = try await store.read()
            guard live(start) else { return }; storeEpoch = epoch
            saved = state.captures.filter { owns($0.capture) }
            storedReviews = state.reviews.filter { owns($0.intent) }
            selected = saved.first { $0.report != nil && $0.receipt == nil && $0.status == nil } ?? saved.last
            occurredAt = selected?.report.flatMap { PlacementDate.date($0.occurredAt) } ?? clock()
        } catch { if live(start) { await fail(error, reviewer: false) } }
    }
    func selectSaved(id: String) {
        guard authorized, !busy, let record = saved.first(where: { $0.id == id }) else { return }
        selected = record; occurredAt = record.report.flatMap { PlacementDate.date($0.occurredAt) } ?? clock(); cancelReview()
    }
    func discardUnreportedCapture() async {
        guard authorized, !busy, let selected, selected.report == nil, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            try await store.discardUnreportedCapture(id: selected.id, expectedEpoch: epoch)
            guard live(start) else { return }; saved.removeAll { $0.id == selected.id }; self.selected = saved.last; cancelReview()
            notice = PlacementCopy.text("The unused local snapshot was removed. No placement report was removed or sent. Refresh and review the current shop before saving another snapshot.")
        } catch { if live(start) { await fail(error, reviewer: false) } }
    }
    func refreshCurrent() async {
        guard canManage, !busy, let id = scope?.currentShopID else { return }
        busy = true; defer { busy = false }; let start = generation
        currentShop = nil; reportPage = nil; pendingReview = nil; seenCursors = []; cancelReview()
        do {
            let shop = try await service.placementShop(shopID: id)
            let page = try await service.pendingPlacementReports(shopID: id, cursor: nil)
            guard live(start), canManage else { return }
            guard shop.shopId == page.shopId, shop.shopRevision == page.shopRevision, shop.authorityEpoch == page.authorityEpoch,
                  shop.phase == page.phase, shop.frozenRevision == page.frozenRevision else { throw ClientError.service(status: 409, code: "source_changed", correlationID: nil, retryAfter: nil) }
            currentShop = shop; reportPage = page
            pendingReview = storedReviews.first { $0.intent.shopID == id && !$0.retired && $0.receipt == nil }
            notice = nil
        } catch { if live(start) { await fail(error, reviewer: true) } }
    }
    func loadReports(more: Bool = false) async {
        if !more { await refreshCurrent(); return }
        guard canManage, !busy, let prior = reportPage, let cursor = prior.nextCursor else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            let page = try await service.pendingPlacementReports(shopID: prior.shopId, cursor: cursor)
            guard live(start), canManage else { return }
            guard page.shopId == prior.shopId, page.shopRevision == prior.shopRevision, page.authorityEpoch == prior.authorityEpoch,
                  page.phase == prior.phase, page.frozenRevision == prior.frozenRevision,
                  Set(page.reports.map(\.reportId)).isDisjoint(with: prior.reports.map(\.reportId)),
                  page.nextCursor == nil || (page.nextCursor != cursor && !seenCursors.contains(page.nextCursor!)) else { throw ClientError.invalidResponse }
            reportPage = .init(shopId: prior.shopId, shopRevision: prior.shopRevision, authorityEpoch: prior.authorityEpoch,
                               phase: prior.phase, frozenRevision: prior.frozenRevision, reports: prior.reports + page.reports, nextCursor: page.nextCursor)
            seenCursors.insert(cursor)
        } catch { if live(start) { reportPage = nil; await fail(error, reviewer: true) } }
    }
    func reviewCapture() {
        guard canCapture, let currentShop else { return }
        reviewed = .capture(currentShop); approved = false; notice = nil
    }
    func reviewReport() {
        guard canReport, let selected else { return }
        do {
            guard let captured = PlacementDate.date(selected.capture.capturedAt), occurredAt >= captured,
                  occurredAt <= clock().addingTimeInterval(300) else { throw ClientError.configuration }
            reviewed = .report(try selected.capture.report(occurredAt: PlacementDate.string(occurredAt))); approved = false; notice = nil
        } catch { cancelReview(); notice = PlacementCopy.text("Enter when you placed this reviewed snapshot, after it was saved and no later than five minutes from now.") }
    }
    func reviewReconciliation(_ report: PlacementPendingReport, choice: PlacementReviewChoice) {
        guard canManage, !busy, pendingReview == nil, let page = reportPage, let currentShop,
              page.reports.contains(report), report.state == "pending_reconciliation",
              currentShop.shopRevision == page.shopRevision, currentShop.authorityEpoch == page.authorityEpoch else { return }
        if choice == .apply && (page.phase != "frozen" || page.frozenRevision != report.reportedRevision) {
            notice = PlacementCopy.text("This report does not match the current frozen basket. Preserve both records and review the difference; it cannot be applied here."); return
        }
        reviewed = .reconcile(page: page, report: report, choice: choice); approved = false; notice = nil
    }
    func applyReviewed() async {
        guard canApply, let action = reviewed, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; let start = generation; notice = nil
        do {
            switch action {
            case .capture(let snapshot):
                guard canManage else { return }
                let capture = try await service.preparePlacementSnapshot(reviewed: snapshot)
                guard live(start), reviewed == action, approved, owns(capture) else { return }
                try await store.saveCapture(capture, expectedEpoch: epoch)
                guard live(start) else { return }
                let record = PlacementLocalRecord(capture: capture); saved.append(record); selected = record; occurredAt = clock(); cancelReview()
                notice = PlacementCopy.text("The reviewed snapshot and its original action identity are saved on this iPhone. Saving is not an order or a placement report.")
            case .report(let intent):
                guard selected?.capture == intent.prepared, selected?.report == nil else { return }
                // This seal needs no connection. The original time, base, key, window and bytes are durable before delivery.
                try await store.sealReport(intent, expectedEpoch: epoch)
                guard live(start) else { return }
                updateSelected(id: intent.id) { $0.report = intent }; cancelReview()
                await deliverReport(intent, start: start, epoch: epoch)
            case .reconcile(let page, let report, let choice):
                guard canManage, pendingReview == nil, let snapshot = currentShop else { return }
                let intent = try await service.preparePlacementReview(page: page, report: report, choice: choice)
                guard live(start), reviewed == action, approved else { return }
                let record = PlacementLocalReview(intent: intent, currentSnapshot: snapshot)
                try await store.saveReview(record, expectedEpoch: epoch)
                guard live(start) else { return }; storedReviews.append(record); pendingReview = record; cancelReview()
                await deliverReview(intent, start: start, epoch: epoch)
            }
        } catch { if live(start) { cancelReview(); await fail(error, reviewer: { if case .report = action { return false }; return true }()) } }
    }
    func retryReport() async {
        guard authorized, !busy, let selected, let intent = selected.report, selected.receipt == nil, selected.status == nil, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; notice = nil
        await deliverReport(intent, start: generation, epoch: epoch)
    }
    private func deliverReport(_ intent: PlacementReportIntent, start: UUID, epoch: UUID) async {
        do {
            let receipt: PlacementReporterReceipt
            if reportReceiptInMemory?.id == intent.id { receipt = reportReceiptInMemory!.receipt }
            else {
                guard PlacementDate.date(intent.prepared.replayWindow.expiresAt).map({ $0 > clock() }) == true else {
                    notice = PlacementCopy.text("The original sending window expired. Check this report's recorded status. Its original evidence remains saved; no new report or sending window was created."); return
                }
                receipt = try await service.executePlacementReport(intent)
                guard live(start) else { return }; reportReceiptInMemory = (intent.id, receipt)
            }
            try await store.recordReportReceipt(id: intent.id, receipt: receipt, expectedEpoch: epoch)
            guard live(start) else { return }; updateSelected(id: intent.id) { $0.receipt = receipt }; reportReceiptInMemory = nil
            notice = PlacementCopy.text("The service recorded your manual placement report. This is not retailer or payment confirmation.")
        } catch {
            guard live(start) else { return }
            if reportReceiptInMemory?.id == intent.id {
                notice = PlacementCopy.text("The service confirmed your placement report, but its receipt could not be saved on this iPhone. Retry to save that same receipt without sending another report.")
            } else { await fail(error, reviewer: false) }
        }
    }
    func refreshReporterStatus() async {
        guard authorized, !busy, let selected, let intent = selected.report, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            let status = try await service.placementReportStatus(intent)
            guard live(start) else { return }
            if let status {
                try await store.recordReportStatus(id: intent.id, status: status, expectedEpoch: epoch)
                guard live(start) else { return }; updateSelected(id: intent.id) { $0.status = status }
                notice = PlacementCopy.text("The original report's recorded status was checked without creating another placement report.")
            } else { notice = PlacementCopy.text("No recorded result was found for this exact report. Its original evidence remains saved. If its sending window expired, review that evidence with the current shopper.") }
        } catch { if live(start) { await fail(error, reviewer: false) } }
    }
    func retryReconciliation() async {
        guard canManage, !busy, let pendingReview, !pendingReview.retired, pendingReview.receipt == nil,
              pendingReview.status == nil || pendingReview.status?.report.state == "pending_reconciliation",
              pendingReview.intent.shopID == scope?.currentShopID, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; notice = nil
        await deliverReview(pendingReview.intent, start: generation, epoch: epoch)
    }
    private func deliverReview(_ intent: PlacementReviewIntent, start: UUID, epoch: UUID) async {
        do {
            let receipt: PlacementReviewReceipt
            if reviewReceiptInMemory?.id == intent.id { receipt = reviewReceiptInMemory!.receipt }
            else {
                guard PlacementDate.date(intent.replayWindow.expiresAt).map({ $0 > clock() }) == true else {
                    notice = PlacementCopy.text("This reconciliation's original sending window expired. Check the current report status before reviewing another action."); return
                }
                receipt = try await service.executePlacementReview(intent)
                guard live(start) else { return }; reviewReceiptInMemory = (intent.id, receipt)
            }
            try await store.recordReviewReceipt(id: intent.id, receipt: receipt, expectedEpoch: epoch)
            guard live(start) else { return }
            if let index = storedReviews.firstIndex(where: { $0.id == intent.id }) { storedReviews[index].receipt = receipt }
            pendingReview = nil; reviewReceiptInMemory = nil; currentShop = nil; reportPage = nil
            notice = PlacementCopy.text("The reviewed reconciliation was recorded. Refresh the current shop before making another decision.")
        } catch {
            guard live(start) else { return }
            if reviewReceiptInMemory?.id == intent.id {
                notice = PlacementCopy.text("The service confirmed your reconciliation, but its receipt could not be saved on this iPhone. Retry to save that same receipt without sending another command.")
            } else { await fail(error, reviewer: true) }
        }
    }
    func refreshReconciliationStatus() async { await checkReconciliationStatus(retire: false) }
    func retireReconciliationAfterStatusReview() async { await checkReconciliationStatus(retire: true) }
    private func checkReconciliationStatus(retire: Bool) async {
        guard canManage, !busy, let review = pendingReview, review.intent.shopID == scope?.currentShopID, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            let status = try await service.placementReport(shopID: review.intent.shopID, reportID: review.intent.report.reportId)
            guard live(start), canManage else { return }
            try await store.recordReviewStatus(id: review.id, status: status, retire: retire, expectedEpoch: epoch)
            guard live(start) else { return }
            if let index = storedReviews.firstIndex(where: { $0.id == review.id }) { storedReviews[index].status = status; storedReviews[index].retired = retire; pendingReview = retire ? nil : storedReviews[index] }
            if retire { currentShop = nil; reportPage = nil; cancelReview(); notice = PlacementCopy.text("The local reconciliation retry was retired after checking current status. Its original evidence remains saved. This does not undo a shared action; refresh and review before starting another.") }
            else { notice = PlacementCopy.text("The current report status is shown. A matching resolution action identifies your original reconciliation; no new command was sent.") }
        } catch { if live(start) { await fail(error, reviewer: true) } }
    }
    private func updateSelected(id: String, _ update: (inout PlacementLocalRecord) -> Void) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }; update(&saved[index]); if selected?.id == id { selected = saved[index] }
    }
    private func fail(_ error: Error, reviewer: Bool) async {
        switch error as? ClientError {
        case .sessionNeeded, .accessEnded:
            invalidate(); await onAccessEnded()
        case .cancelled: break
        case .service(let status, let code, _, _):
            if status == 404 || status == 403 {
                if reviewer { currentShop = nil; reportPage = nil; pendingReview = nil; cancelReview() }
                notice = PlacementCopy.text("Current shopper access is unavailable. Your own original placement evidence remains separate and unchanged.")
            } else if code == "refresh_required" {
                notice = PlacementCopy.text("The original sending window is unavailable. Check recorded status and keep the original evidence; this app will not create another report silently.")
            } else if status == 409 {
                cancelReview(); notice = PlacementCopy.text("The shared facts changed. Keep the existing retry, check current status, and explicitly review any new reconciliation.")
            } else { notice = PlacementCopy.text("The result is not confirmed. Your original evidence and exact retry remain on this iPhone.") }
        default: notice = PlacementCopy.text("The result is not confirmed. Your original evidence and exact retry remain on this iPhone.")
        }
    }
}
