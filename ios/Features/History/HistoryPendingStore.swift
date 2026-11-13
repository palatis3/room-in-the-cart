import Foundation
import HouseholdClient

enum HistoryPendingWrite: Codable, Equatable, Identifiable, Sendable {
    case observation(PriceObservationIntent)
    case period(BudgetPeriodIntent)
    var id: String { switch self { case .observation(let v): return v.id; case .period(let v): return v.id } }
    var subject: String { switch self { case .observation(let v): return v.subject; case .period(let v): return v.subject } }
    var householdID: String { switch self { case .observation(let v): return v.householdID; case .period(let v): return v.householdID } }
    var memberID: String { switch self { case .observation(let v): return v.memberID; case .period(let v): return v.memberID } }
    func validate() throws { switch self { case .observation(let v): try v.validate(); case .period(let v): try v.validate() } }
    func matches(_ scope: HistoryRuntimeScope) -> Bool {
        subject == scope.subject && householdID == scope.householdID && memberID == scope.memberID
    }
}

struct HistoryStoredReference: Codable, Equatable, Sendable {
    let subject: String; let householdID: String; let memberID: String; let shopID: String; let observationID: String
    func matches(_ scope: HistoryRuntimeScope) -> Bool {
        subject == scope.subject && householdID == scope.householdID && memberID == scope.memberID
    }
}
struct HistoryStoredState: Codable, Equatable, Sendable {
    var pending: [HistoryPendingWrite] = []
    var observations: [HistoryStoredReference] = []
    var familyDecisions: FamilyDecisionCache?
    var financialChanges: [ShopperFinancialIntent]?
    var sharedMealChanges: [SharedMealChangeIntent]?
}
protocol HistoryPersisting: Sendable {
    func epoch() async -> UUID
    func read() async throws -> HistoryStoredState
    func save(_ pending: HistoryPendingWrite, expectedEpoch: UUID) async throws
    func complete(_ pending: HistoryPendingWrite, expectedEpoch: UUID) async throws
    func remove(id: String, expectedEpoch: UUID) async throws
    func remember(_ reference: HistoryStoredReference, expectedEpoch: UUID) async throws
}

/// Private retry bytes and bare saved-record references, never cached authority or budget totals.
/// Actor-atomic updates and the epoch prevent pre-deletion work from restoring erased data.
actor HistoryPendingStore: HistoryPersisting {
    private let url: URL
    private var generation = UUID()
    init(url: URL) { self.url = url }
    func epoch() -> UUID { generation }
    func read() throws -> HistoryStoredState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(HistoryStoredState.self, from: Data(contentsOf: url))
    }
    func save(_ pending: HistoryPendingWrite, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        try pending.validate()
        var state = try read()
        if let existing = state.pending.first(where: { $0.id == pending.id }) {
            guard existing == pending else { throw ClientError.configuration }; return
        }
        guard !state.pending.contains(where: { $0.subject == pending.subject && $0.householdID == pending.householdID && $0.memberID == pending.memberID }) else {
            throw ClientError.service(status: 409, code: "history_pending", correlationID: nil, retryAfter: nil)
        }
        state.pending.append(pending); try write(state)
    }
    func complete(_ pending: HistoryPendingWrite, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var state = try read()
        state.pending.removeAll { $0.id == pending.id }
        if case .observation(let value) = pending {
            let reference = HistoryStoredReference(subject: value.subject, householdID: value.householdID, memberID: value.memberID, shopID: value.observation.shopId, observationID: value.observation.id)
            if !state.observations.contains(reference) { state.observations.append(reference) }
        }
        try write(state)
    }
    func remove(id: String, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var state = try read(); state.pending.removeAll { $0.id == id }; try write(state)
    }
    func remember(_ reference: HistoryStoredReference, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch, UUID(uuidString: reference.observationID) != nil else { throw ClientError.cancelled }
        var state = try read()
        if !state.observations.contains(reference) { state.observations.append(reference); try write(state) }
    }
    func stageDecision(_ intent: FamilyDecisionIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        try intent.validate()
        var state = try read(), cache = state.familyDecisions ?? .init()
        if let pending = cache.pending.first(where: {
            $0.householdID == intent.householdID && $0.memberID == intent.memberID && $0.subject == intent.subject
        }) {
            guard pending == intent else { throw ClientError.configuration }
            return
        }
        cache.pending.append(intent)
        state.familyDecisions = cache
        try write(state)
    }
    func finishDecision(_ intent: FamilyDecisionIntent, confirmed: Bool, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var state = try read(), cache = state.familyDecisions ?? .init()
        guard cache.pending.contains(intent) else { throw ClientError.cancelled }
        cache.pending.removeAll { $0 == intent }
        if confirmed {
            let ref = FamilyDecisionReference(subject: intent.subject, householdID: intent.householdID,
                memberID: intent.memberID, shopID: intent.shopID, id: intent.recordID)
            if !cache.records.contains(ref) { cache.records.append(ref) }
        }
        state.familyDecisions = cache
        try write(state)
    }
    func stageFinancial(_ intent: ShopperFinancialIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var state = try read()
        if let existing = state.financialChanges?.first(where: {
            $0.subject == intent.subject && $0.householdID == intent.householdID && $0.memberID == intent.memberID && $0.shopID == intent.shopID
        }) {
            guard existing == intent else { throw ClientError.configuration }
            return
        }
        state.financialChanges = (state.financialChanges ?? []) + [intent]
        try write(state)
    }
    func finishFinancial(_ intent: ShopperFinancialIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var state = try read()
        guard state.financialChanges?.contains(intent) == true else { throw ClientError.cancelled }
        state.financialChanges?.removeAll { $0 == intent }
        try write(state)
    }
    func stageMealChange(_ intent: SharedMealChangeIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        try intent.validate()
        var state = try read(), pending = state.sharedMealChanges ?? []
        if let previous = pending.first(where: { $0.subject == intent.subject && $0.householdID == intent.householdID && $0.memberID == intent.memberID && $0.shopID == intent.shopID }) {
            guard previous == intent else { throw ClientError.configuration }; return
        }
        pending.append(intent); state.sharedMealChanges = pending; try write(state)
    }
    func finishMealChange(_ intent: SharedMealChangeIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var state = try read()
        guard state.sharedMealChanges?.contains(intent) == true else { throw ClientError.cancelled }
        state.sharedMealChanges?.removeAll { $0 == intent }; try write(state)
    }
    func purge(householdID: String, subject: String) throws {
        generation = UUID()
        var state = try read()
        state.pending.removeAll { $0.householdID == householdID && $0.subject == subject }
        state.financialChanges?.removeAll { $0.householdID == householdID && $0.subject == subject }
        state.sharedMealChanges?.removeAll { $0.householdID == householdID && $0.subject == subject }
        state.observations.removeAll { $0.householdID == householdID && $0.subject == subject }
        state.familyDecisions?.pending.removeAll { $0.householdID == householdID && $0.subject == subject }
        state.familyDecisions?.records.removeAll { $0.householdID == householdID && $0.subject == subject }
        try write(state)
    }
    func purge() throws { generation = UUID(); try write(.init()) }
    private func write(_ state: HistoryStoredState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
}
