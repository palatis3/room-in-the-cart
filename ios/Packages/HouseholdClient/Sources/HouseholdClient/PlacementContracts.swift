import Foundation
import CryptoKit

public struct PlacementPreparedSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let snapshot: ShopperShop; public let replayWindow: ReplayWindow; public let capturedAt: String
    public init(id: String = UUID().uuidString.lowercased(), subject: String, householdID: String, memberID: String, deviceID: String,
                snapshot: ShopperShop, replayWindow: ReplayWindow, capturedAt: String) throws {
        self.id = id; self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID
        self.snapshot = snapshot; self.replayWindow = replayWindow; self.capturedAt = capturedAt; try validate()
    }
    public func validate() throws {
        try HistoryValidation.scope(id: id, subject: subject, household: householdID, member: memberID, device: deviceID)
        guard HistoryValidation.ids([snapshot.shopId, replayWindow.id]), snapshot.shopRevision > 0, snapshot.authorityEpoch > 0,
              ["draft", "frozen"].contains(snapshot.phase), snapshot.phase != "frozen" || snapshot.frozenRevision == snapshot.shopRevision,
              let captured = HistoryValidation.date(capturedAt), let expires = HistoryValidation.date(replayWindow.expiresAt), expires > captured,
              snapshot.lines.count <= 200, HistoryValidation.uniqueIDs(snapshot.lines.map(\.lineId)) else { throw ClientError.configuration }
    }
    /// Local sealing only. The original key, window, snapshot and authority epoch do not change offline.
    public func report(occurredAt: String) throws -> PlacementReportIntent { try .init(prepared: self, occurredAt: occurredAt) }
}
public struct PlacementReportIntent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { prepared.id }
    public var subject: String { prepared.subject }; public var householdID: String { prepared.householdID }
    public var memberID: String { prepared.memberID }; public var deviceID: String { prepared.deviceID }; public var shopID: String { prepared.snapshot.shopId }
    public let prepared: PlacementPreparedSnapshot; public let occurredAt: String; public let bytes: Data
    public var commandDigest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public init(prepared: PlacementPreparedSnapshot, occurredAt: String) throws {
        try prepared.validate(); self.prepared = prepared; self.occurredAt = occurredAt
        bytes = try Self.payload(prepared, occurredAt); try validate()
    }
    private static func payload(_ prepared: PlacementPreparedSnapshot, _ occurredAt: String) throws -> Data {
        guard let key = UUID(uuidString: prepared.id) else { throw ClientError.configuration }
        return try encoded(CommandEnvelope(replayWindow: prepared.replayWindow.id, clientKey: key, shopId: prepared.snapshot.shopId,
            kind: "shop.reportPlaced", base: .init(shopRevision: prepared.snapshot.shopRevision, authorityEpoch: prepared.snapshot.authorityEpoch),
            body: ["occurredAt": .string(occurredAt)]))
    }
    public func validate() throws {
        try prepared.validate()
        guard HistoryValidation.date(occurredAt) != nil, bytes == (try Self.payload(prepared, occurredAt)) else { throw ClientError.configuration }
    }
}
public struct PlacementReporterReceipt: Codable, Equatable, Sendable {
    public let operationId: String; public let kind: String; public let reportId: String; public let disposition: String
    public init(operationId: String, kind: String = "shop.reportPlaced", reportId: String, disposition: String) {
        self.operationId = operationId; self.kind = kind; self.reportId = reportId; self.disposition = disposition
    }
    private enum CodingKeys: String, CodingKey { case operationId, kind, reportId, disposition }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: HistoryCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["operationId", "kind", "reportId", "disposition"] else { throw ClientError.invalidResponse }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try c.decode(String.self, forKey: .operationId); kind = try c.decode(String.self, forKey: .kind)
        reportId = try c.decode(String.self, forKey: .reportId); disposition = try c.decode(String.self, forKey: .disposition)
    }
    func validate() throws { guard HistoryValidation.ids([operationId, reportId]), kind == "shop.reportPlaced", ["placed", "pending_reconciliation"].contains(disposition) else { throw ClientError.invalidResponse } }
}
public struct PlacementReporterStatus: Codable, Equatable, Sendable {
    public let clientKey: String; public let operationId: String; public let reportId: String; public let shopId: String
    public let reportedRevision: Int; public let reportedAuthorityEpoch: Int; public let occurredAt: String; public let receivedAt: String; public let source: String; public let state: String
    public init(clientKey: String, operationId: String, reportId: String, shopId: String, reportedRevision: Int, reportedAuthorityEpoch: Int, occurredAt: String, receivedAt: String, source: String = "shopper_reported", state: String) {
        self.clientKey = clientKey; self.operationId = operationId; self.reportId = reportId; self.shopId = shopId
        self.reportedRevision = reportedRevision; self.reportedAuthorityEpoch = reportedAuthorityEpoch; self.occurredAt = occurredAt; self.receivedAt = receivedAt; self.source = source; self.state = state
    }
    private enum CodingKeys: String, CodingKey { case clientKey, operationId, reportId, shopId, reportedRevision, reportedAuthorityEpoch, occurredAt, receivedAt, source, state }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: HistoryCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["clientKey", "operationId", "reportId", "shopId", "reportedRevision", "reportedAuthorityEpoch", "occurredAt", "receivedAt", "source", "state"] else { throw ClientError.invalidResponse }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientKey = try c.decode(String.self, forKey: .clientKey); operationId = try c.decode(String.self, forKey: .operationId)
        reportId = try c.decode(String.self, forKey: .reportId); shopId = try c.decode(String.self, forKey: .shopId)
        reportedRevision = try c.decode(Int.self, forKey: .reportedRevision); reportedAuthorityEpoch = try c.decode(Int.self, forKey: .reportedAuthorityEpoch)
        occurredAt = try c.decode(String.self, forKey: .occurredAt); receivedAt = try c.decode(String.self, forKey: .receivedAt)
        source = try c.decode(String.self, forKey: .source); state = try c.decode(String.self, forKey: .state)
    }
    func validate(_ intent: PlacementReportIntent) throws {
        guard HistoryValidation.sameID(clientKey, intent.id), HistoryValidation.ids([operationId, reportId]), HistoryValidation.sameID(shopId, intent.shopID),
              reportedRevision == intent.prepared.snapshot.shopRevision, reportedAuthorityEpoch == intent.prepared.snapshot.authorityEpoch,
              HistoryValidation.date(occurredAt) == HistoryValidation.date(intent.occurredAt), HistoryValidation.date(receivedAt) != nil,
              source == "shopper_reported", ["pending_reconciliation", "applied", "rejected"].contains(state) else { throw ClientError.invalidResponse }
    }
}
public struct PlacementReportedSnapshot: Codable, Equatable, Sendable {
    public struct MealReference: Codable, Equatable, Sendable {
        public let occurrenceId: String; public let revision: Int
        public init(occurrenceId: String, revision: Int) { self.occurrenceId = occurrenceId; self.revision = revision }
    }
    public let shopId: String; public let revision: Int; public let phase: String; public let quote: ShopperQuote
    public let lines: [ShopperBasketLine]; public let budget: ShopperBudget; public let mealRefs: [MealReference]?
    public init(shopId: String, revision: Int, phase: String, quote: ShopperQuote, lines: [ShopperBasketLine], budget: ShopperBudget, mealRefs: [MealReference]? = nil) {
        self.shopId = shopId; self.revision = revision; self.phase = phase; self.quote = quote; self.lines = lines; self.budget = budget; self.mealRefs = mealRefs
    }
}
public struct PlacementPendingReport: Codable, Equatable, Identifiable, Sendable {
    public var id: String { reportId }
    public let reportId: String; public let shopId: String; public let reportedRevision: Int; public let reportedAuthorityEpoch: Int
    public let occurredAt: String; public let receivedAt: String; public let source: String; public let state: String
    public let snapshot: PlacementReportedSnapshot; public let snapshotCreatedAt: String; public let snapshotDigest: String
    public let resolutionOperationId: String?; public let resolutionClientKey: String?
    public init(reportId: String, shopId: String, reportedRevision: Int, reportedAuthorityEpoch: Int, occurredAt: String, receivedAt: String,
                source: String = "shopper_reported", state: String, snapshot: PlacementReportedSnapshot, snapshotCreatedAt: String, snapshotDigest: String,
                resolutionOperationId: String? = nil, resolutionClientKey: String? = nil) {
        self.reportId = reportId; self.shopId = shopId; self.reportedRevision = reportedRevision; self.reportedAuthorityEpoch = reportedAuthorityEpoch
        self.occurredAt = occurredAt; self.receivedAt = receivedAt; self.source = source; self.state = state; self.snapshot = snapshot
        self.snapshotCreatedAt = snapshotCreatedAt; self.snapshotDigest = snapshotDigest; self.resolutionOperationId = resolutionOperationId; self.resolutionClientKey = resolutionClientKey
    }
    func validate(shopID: String) throws {
        guard HistoryValidation.ids([reportId, shopId]), HistoryValidation.sameID(shopId, shopID), HistoryValidation.sameID(snapshot.shopId, shopID),
              reportedRevision > 0, reportedAuthorityEpoch > 0, snapshot.revision == reportedRevision,
              HistoryValidation.date(occurredAt) != nil, HistoryValidation.date(receivedAt) != nil, HistoryValidation.date(snapshotCreatedAt) != nil,
              snapshotDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, source == "shopper_reported",
              ["pending_reconciliation", "applied", "rejected"].contains(state), snapshot.lines.count <= 200,
              HistoryValidation.uniqueIDs(snapshot.lines.map(\.lineId)), snapshot.quote.currency == "USD", snapshot.budget.currency == "USD",
              resolutionOperationId.map({ HistoryValidation.ids([$0]) }) ?? true, resolutionClientKey.map({ HistoryValidation.ids([$0]) }) ?? true,
              state != "pending_reconciliation" || (resolutionOperationId == nil && resolutionClientKey == nil) else { throw ClientError.invalidResponse }
    }
}
public struct PlacementReportPage: Codable, Equatable, Sendable {
    public let shopId: String; public let shopRevision: Int; public let authorityEpoch: Int; public let phase: String; public let frozenRevision: Int?
    public let reports: [PlacementPendingReport]; public let nextCursor: String?
    public init(shopId: String, shopRevision: Int, authorityEpoch: Int, phase: String, frozenRevision: Int?, reports: [PlacementPendingReport], nextCursor: String?) {
        self.shopId = shopId; self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.phase = phase; self.frozenRevision = frozenRevision; self.reports = reports; self.nextCursor = nextCursor
    }
    public var base: CommandBase { .init(shopRevision: shopRevision, authorityEpoch: authorityEpoch) }
}
public struct PlacementReportDetail: Codable, Equatable, Sendable {
    public let shopId: String; public let shopRevision: Int; public let authorityEpoch: Int; public let phase: String; public let frozenRevision: Int?
    public let report: PlacementPendingReport
    public init(shopId: String, shopRevision: Int, authorityEpoch: Int, phase: String, frozenRevision: Int?, report: PlacementPendingReport) {
        self.shopId = shopId; self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.phase = phase; self.frozenRevision = frozenRevision; self.report = report
    }
    public var page: PlacementReportPage { .init(shopId: shopId, shopRevision: shopRevision, authorityEpoch: authorityEpoch, phase: phase, frozenRevision: frozenRevision, reports: [report], nextCursor: nil) }
}
public enum PlacementReviewChoice: String, Codable, CaseIterable, Sendable { case apply, reject }
public struct PlacementReviewIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let shopID: String; public let report: PlacementPendingReport; public let base: CommandBase; public let choice: PlacementReviewChoice
    public let replayWindow: ReplayWindow; public let bytes: Data
    public init(id: String = UUID().uuidString.lowercased(), subject: String, householdID: String, memberID: String, deviceID: String,
                page: PlacementReportPage, report: PlacementPendingReport, choice: PlacementReviewChoice, replayWindow: ReplayWindow) throws {
        self.id = id; self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID
        shopID = page.shopId; self.report = report; base = page.base; self.choice = choice; self.replayWindow = replayWindow
        guard choice != .apply || (page.phase == "frozen" && page.frozenRevision == report.reportedRevision) else { throw ClientError.configuration }
        bytes = try Self.payload(id: id, shopID: shopID, reportID: report.reportId, base: base, choice: choice, window: replayWindow.id); try validate()
    }
    private static func payload(id: String, shopID: String, reportID: String, base: CommandBase, choice: PlacementReviewChoice, window: String) throws -> Data {
        guard let key = UUID(uuidString: id) else { throw ClientError.configuration }
        return try encoded(CommandEnvelope(replayWindow: window, clientKey: key, shopId: shopID, kind: "shop.reconcileReport", base: base,
                                           body: ["reportId": .string(reportID), "choice": .string(choice.rawValue)]))
    }
    public func validate() throws {
        try HistoryValidation.scope(id: id, subject: subject, household: householdID, member: memberID, device: deviceID); try report.validate(shopID: shopID)
        guard HistoryValidation.ids([shopID, replayWindow.id]), base.shopRevision > 0, base.shopRevision < Int.max, base.authorityEpoch > 0, base.requestRevision == nil,
              report.state == "pending_reconciliation", HistoryValidation.date(replayWindow.expiresAt) != nil,
              bytes == (try Self.payload(id: id, shopID: shopID, reportID: report.reportId, base: base, choice: choice, window: replayWindow.id)) else { throw ClientError.configuration }
    }
}
public struct PlacementReviewReceipt: Codable, Equatable, Sendable {
    public let operationId: String; public let kind: String; public let shopId: String; public let shopRevision: Int; public let authorityEpoch: Int
    public let disposition: String; public let reportId: String
    public init(operationId: String, kind: String = "shop.reconcileReport", shopId: String, shopRevision: Int, authorityEpoch: Int, disposition: String, reportId: String) {
        self.operationId = operationId; self.kind = kind; self.shopId = shopId; self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.disposition = disposition; self.reportId = reportId
    }
    func validate(_ intent: PlacementReviewIntent) throws {
        guard HistoryValidation.ids([operationId]), kind == "shop.reconcileReport", HistoryValidation.sameID(shopId, intent.shopID), reportId == intent.report.reportId,
              authorityEpoch == intent.base.authorityEpoch, shopRevision == intent.base.shopRevision + (intent.choice == .apply ? 1 : 0),
              disposition == (intent.choice == .apply ? "placed" : "report_rejected") else { throw ClientError.invalidResponse }
    }
}
