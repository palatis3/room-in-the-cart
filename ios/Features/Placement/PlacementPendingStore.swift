import Foundation
import HouseholdClient

struct PlacementLocalRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { capture.id }
    let capture: PlacementPreparedSnapshot
    var report: PlacementReportIntent?
    var receipt: PlacementReporterReceipt?
    var status: PlacementReporterStatus?
    init(capture: PlacementPreparedSnapshot) { self.capture = capture }
}
struct PlacementLocalReview: Codable, Equatable, Identifiable, Sendable {
    var id: String { intent.id }
    let intent: PlacementReviewIntent
    let currentSnapshot: ShopperShop
    var receipt: PlacementReviewReceipt?
    var status: PlacementReportDetail?
    var retired = false
    init(intent: PlacementReviewIntent, currentSnapshot: ShopperShop) { self.intent = intent; self.currentSnapshot = currentSnapshot }
}
struct PlacementStoredState: Codable, Equatable, Sendable {
    var captures: [PlacementLocalRecord] = []
    var reviews: [PlacementLocalReview] = []
}
protocol PlacementPersisting: Sendable {
    func epoch() async -> UUID
    func read() async throws -> PlacementStoredState
    func saveCapture(_ capture: PlacementPreparedSnapshot, expectedEpoch: UUID) async throws
    func sealReport(_ intent: PlacementReportIntent, expectedEpoch: UUID) async throws
    func discardUnreportedCapture(id: String, expectedEpoch: UUID) async throws
    func recordReportReceipt(id: String, receipt: PlacementReporterReceipt, expectedEpoch: UUID) async throws
    func recordReportStatus(id: String, status: PlacementReporterStatus, expectedEpoch: UUID) async throws
    func saveReview(_ review: PlacementLocalReview, expectedEpoch: UUID) async throws
    func recordReviewReceipt(id: String, receipt: PlacementReviewReceipt, expectedEpoch: UUID) async throws
    func recordReviewStatus(id: String, status: PlacementReportDetail, retire: Bool, expectedEpoch: UUID) async throws
}

/// Native actor-owned evidence, not a cache of present shopper authority. Original report bytes are immutable.
actor PlacementPendingStore: PlacementPersisting {
    private let url: URL
    private var generation = UUID()
    init(url: URL) { self.url = url }
    func epoch() -> UUID { generation }
    func read() throws -> PlacementStoredState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(PlacementStoredState.self, from: Data(contentsOf: url))
    }
    func saveCapture(_ capture: PlacementPreparedSnapshot, expectedEpoch: UUID) throws {
        try check(expectedEpoch); try capture.validate()
        var state = try read()
        if let prior = state.captures.first(where: { $0.id == capture.id }) { guard prior.capture == capture else { throw ClientError.configuration }; return }
        guard !state.captures.contains(where: { $0.capture.subject == capture.subject && $0.capture.householdID == capture.householdID &&
            $0.capture.memberID == capture.memberID && $0.capture.snapshot.shopId == capture.snapshot.shopId &&
            $0.capture.snapshot.shopRevision == capture.snapshot.shopRevision && $0.capture.snapshot.authorityEpoch == capture.snapshot.authorityEpoch }) else {
            throw ClientError.service(status: 409, code: "placement_snapshot_saved", correlationID: nil, retryAfter: nil)
        }
        state.captures.append(.init(capture: capture)); try write(state)
    }
    func discardUnreportedCapture(id: String, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard let index = state.captures.firstIndex(where: { $0.id == id }), state.captures[index].report == nil,
              state.captures[index].receipt == nil, state.captures[index].status == nil else { throw ClientError.configuration }
        state.captures.remove(at: index); try write(state)
    }
    func sealReport(_ intent: PlacementReportIntent, expectedEpoch: UUID) throws {
        try check(expectedEpoch); try intent.validate()
        var state = try read()
        guard let index = state.captures.firstIndex(where: { $0.id == intent.id }), state.captures[index].capture == intent.prepared else { throw ClientError.configuration }
        if let prior = state.captures[index].report { guard prior == intent else { throw ClientError.configuration }; return }
        guard state.captures[index].receipt == nil && state.captures[index].status == nil else { throw ClientError.configuration }
        state.captures[index].report = intent; try write(state)
    }
    func recordReportReceipt(id: String, receipt: PlacementReporterReceipt, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard let index = state.captures.firstIndex(where: { $0.id == id }), state.captures[index].report != nil else { throw ClientError.configuration }
        if let old = state.captures[index].receipt { guard old == receipt else { throw ClientError.invalidResponse }; return }
        state.captures[index].receipt = receipt; try write(state)
    }
    func recordReportStatus(id: String, status: PlacementReporterStatus, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard let index = state.captures.firstIndex(where: { $0.id == id }), let report = state.captures[index].report,
              status.clientKey == id, status.shopId == report.prepared.snapshot.shopId,
              status.reportedRevision == report.prepared.snapshot.shopRevision, status.reportedAuthorityEpoch == report.prepared.snapshot.authorityEpoch,
              PlacementDate.date(status.occurredAt) == PlacementDate.date(report.occurredAt) else { throw ClientError.invalidResponse }
        state.captures[index].status = status; try write(state)
    }
    func saveReview(_ review: PlacementLocalReview, expectedEpoch: UUID) throws {
        try check(expectedEpoch); try review.intent.validate()
        guard review.currentSnapshot.shopId == review.intent.shopID, review.currentSnapshot.shopRevision == review.intent.base.shopRevision,
              review.currentSnapshot.authorityEpoch == review.intent.base.authorityEpoch else { throw ClientError.configuration }
        var state = try read()
        if let old = state.reviews.first(where: { $0.id == review.id }) { guard old == review else { throw ClientError.configuration }; return }
        guard !state.reviews.contains(where: { $0.intent.subject == review.intent.subject && $0.intent.householdID == review.intent.householdID &&
            $0.intent.memberID == review.intent.memberID && $0.intent.shopID == review.intent.shopID && !$0.retired && $0.receipt == nil }) else {
            throw ClientError.service(status: 409, code: "placement_review_pending", correlationID: nil, retryAfter: nil)
        }
        state.reviews.append(review); try write(state)
    }
    func recordReviewReceipt(id: String, receipt: PlacementReviewReceipt, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard let index = state.reviews.firstIndex(where: { $0.id == id }) else { throw ClientError.configuration }
        if let old = state.reviews[index].receipt { guard old == receipt else { throw ClientError.invalidResponse }; return }
        state.reviews[index].receipt = receipt; try write(state)
    }
    func recordReviewStatus(id: String, status: PlacementReportDetail, retire: Bool, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard let index = state.reviews.firstIndex(where: { $0.id == id }), state.reviews[index].intent.shopID == status.shopId,
              state.reviews[index].intent.report.reportId == status.report.reportId else { throw ClientError.invalidResponse }
        state.reviews[index].status = status; state.reviews[index].retired = retire; try write(state)
    }
    func purge() throws { generation = UUID(); try write(.init()) }
    func purge(householdID: String, subject: String) throws {
        generation = UUID(); var state = try read()
        state.captures.removeAll { $0.capture.householdID == householdID && $0.capture.subject == subject }
        state.reviews.removeAll { $0.intent.householdID == householdID && $0.intent.subject == subject }; try write(state)
    }
    private func check(_ epoch: UUID) throws { guard generation == epoch else { throw ClientError.cancelled } }
    private func write(_ state: PlacementStoredState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var privateURL = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try privateURL.setResourceValues(values)
    }
}
