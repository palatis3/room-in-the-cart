import Combine
import Foundation
import HouseholdClient

func pantryText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "HouseholdPantry")
}

struct HouseholdPantryRuntime: Equatable {
    let generation: UUID
    let enrollmentRevision: UUID
    let subject: String
    let householdID: String
    let memberID: String
    let managesGrants: Bool
}

struct PendingPantryAddition: PendingShopWrite {
    let subject: String
    let intent: HouseholdPantryIntent

    func validate() throws {
        guard !subject.isEmpty else { throw ClientError.configuration }
        try intent.validate(for: intent.session)
    }
    func sharesScope(with other: Self) -> Bool {
        subject == other.subject && intent.session == other.intent.session
    }
    func belongs(to householdID: String, subject: String) -> Bool {
        self.subject == subject && intent.session.householdID == UUID(uuidString: householdID)
    }
}
typealias HouseholdPantryPendingStore = PendingShopWriteStore<PendingPantryAddition>

extension PendingShopWriteStore where Write == PendingPantryAddition {
    func contains(_ record: Write, expectedEpoch: UUID) throws -> Bool {
        guard epoch() == expectedEpoch else { return false }
        return try read().contains(record)
    }
}

protocol HouseholdPantryServing: Sendable {
    func householdPantrySession(for bootstrap: HouseholdBootstrap) async throws -> HouseholdPantrySession
    func householdPantryPage(for session: HouseholdPantrySession, after previous: HouseholdPantryPage?) async throws -> HouseholdPantryPage
    func prepareHouseholdPantryAddition(_ body: HouseholdPantryAddition, reviewed page: HouseholdPantryPage,
                                        session: HouseholdPantrySession) async throws -> HouseholdPantryIntent
    func submitHouseholdPantryAddition(_ intent: HouseholdPantryIntent, session: HouseholdPantrySession) async throws -> HouseholdPantryReceipt
    func householdPantryGrants(for session: HouseholdPantrySession) async throws -> HouseholdPantryGrants
    func changeHouseholdPantryGrant(_ adult: HouseholdPantryGrants.Adult, enabled: Bool, session: HouseholdPantrySession) async throws -> HouseholdPantryGrants
}
extension HouseholdService: HouseholdPantryServing {}

@MainActor final class HouseholdPantryModel: ObservableObject {
    let scope: HouseholdPantryRuntime
    private let service: any HouseholdPantryServing
    private let store: HouseholdPantryPendingStore
    private let projection: () -> HouseholdBootstrap?
    private let recheckAccess: () async -> Void
    private var generation = UUID()
    private var storeEpoch: UUID?
    private var session: HouseholdPantrySession?
    @Published private(set) var page: HouseholdPantryPage?
    @Published private(set) var lots: [HouseholdPantryPage.Lot] = []
    @Published private(set) var pending: PendingPantryAddition?
    @Published private(set) var grants: HouseholdPantryGrants?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?

    init(scope: HouseholdPantryRuntime, service: any HouseholdPantryServing, store: HouseholdPantryPendingStore,
         projection: @escaping () -> HouseholdBootstrap?, recheckAccess: @escaping () async -> Void) {
        self.scope = scope
        self.service = service
        self.store = store
        self.projection = projection
        self.recheckAccess = recheckAccess
    }

    private func clearFacts() {
        page = nil
        lots.removeAll()
        pending = nil
        grants = nil
        session = nil
        storeEpoch = nil
    }
    func dismiss() {
        generation = UUID()
        clearFacts()
        notice = nil
        busy = false
    }
    private func check(_ start: UUID) throws {
        guard start == generation, projection() != nil, !Task.isCancelled else { throw ClientError.cancelled }
    }

    private func perform(checkingPantryAccess: Bool = true, _ action: (UUID) async throws -> Void) async {
        guard !busy, projection() != nil else { return }
        let start = generation
        busy = true
        notice = nil
        defer { if generation == start { busy = false } }
        do { try await action(start) }
        catch {
            guard start == generation else { return }
            clearFacts()
            guard projection() != nil else { return }
            switch error as? ClientError {
            case .accessEnded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
                notice = pantryText("Pantry access has changed. Check household access again.")
                if checkingPantryAccess {
                    do { try await store.purge(householdID: scope.householdID, subject: scope.subject) }
                    catch { notice = ht("Access has ended. Local retry cleanup could not be confirmed.") }
                }
                await recheckAccess()
            case .sessionNeeded:
                notice = pantryText("Pantry access has changed. Check household access again.")
                await recheckAccess()
            case .service(status: 409, code: _, correlationID: _, retryAfter: _):
                notice = pantryText("The pantry or its permissions changed. Reload and check the stock before adding food.")
            case .cancelled: break
            default: notice = pantryText("The result could not be confirmed. Reload the pantry to check stock and any saved retry.")
            }
        }
    }

    func load() async {
        await perform { start in
            clearFacts()
            try await loadFirstPage(start)
        }
    }
    private func loadFirstPage(_ start: UUID) async throws {
        guard let bootstrap = projection() else { throw ClientError.cancelled }
        let epoch = await store.epoch()
        let currentSession = try await service.householdPantrySession(for: bootstrap)
        try check(start)
        let first = try await service.householdPantryPage(for: currentSession, after: nil)
        try check(start)
        let records = try await store.read()
        try check(start)
        // Re-enrollment and revoke/regrant cannot reveal or submit an earlier command.
        // Shop selection and shopper transfer are absent from durable identity.
        var retry: PendingPantryAddition?
        for record in records where record.belongs(to: scope.householdID, subject: scope.subject) &&
            record.intent.session.memberID == currentSession.memberID {
            if record.intent.session == currentSession && record.intent.grantEpoch == first.grantEpoch {
                retry = record
            } else {
                try await store.complete(record, expectedEpoch: epoch)
                try check(start)
                notice = pantryText("An earlier retry ended when pantry access changed. Check the stock before adding food.")
            }
        }
        session = currentSession
        storeEpoch = epoch
        page = first
        lots = first.lots
        pending = retry
    }

    func loadMore() async {
        guard let session, let previous = page, previous.nextCursor != nil else { return }
        await perform { start in
            let next = try await service.householdPantryPage(for: session, after: previous)
            try check(start)
            lots.append(contentsOf: next.lots)
            page = next
        }
    }

    func confirm(_ addition: HouseholdPantryAddition, reviewed: HouseholdPantryPage) async {
        guard let session, let storeEpoch, pending == nil, page == reviewed else { return }
        await perform { start in
            let intent = try await service.prepareHouseholdPantryAddition(addition, reviewed: reviewed, session: session)
            try check(start)
            let record = PendingPantryAddition(subject: scope.subject, intent: intent)
            try await store.save(record, expectedEpoch: storeEpoch)
            try check(start)
            pending = record
            try await submit(record, session: session, epoch: storeEpoch, start: start)
        }
    }
    func retry() async {
        guard let session, let storeEpoch, let pending, page?.grantEpoch == pending.intent.grantEpoch else { return }
        await perform { start in
            try await submit(pending, session: session, epoch: storeEpoch, start: start)
        }
    }
    private func submit(_ record: PendingPantryAddition, session: HouseholdPantrySession, epoch: UUID, start: UUID) async throws {
        guard try await store.contains(record, expectedEpoch: epoch) else { throw ClientError.cancelled }
        try check(start)
        _ = try await service.submitHouseholdPantryAddition(record.intent, session: session)
        try check(start)
        clearFacts()
        do {
            try await store.complete(record, expectedEpoch: epoch)
            try check(start)
            try await loadFirstPage(start)
            notice = pantryText("Food added to the household pantry.")
        } catch {
            try check(start)
            switch error as? ClientError {
            case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _):
                throw error
            default:
                notice = pantryText("Food added. Reload to see the updated stock.")
            }
        }
    }
    func clearReviewedRetry() async {
        guard let pending, let storeEpoch, let page, pending.intent.grantEpoch == page.grantEpoch else { return }
        await perform { start in
            try await store.complete(pending, expectedEpoch: storeEpoch)
            try check(start)
            self.pending = nil
        }
    }

    func loadGrants() async {
        guard scope.managesGrants, let session else { return }
        await perform(checkingPantryAccess: false) { start in
            grants = nil
            let value = try await service.householdPantryGrants(for: session)
            try check(start)
            grants = value
        }
    }
    func changeGrant(_ adult: HouseholdPantryGrants.Adult) async {
        guard scope.managesGrants, let session, grants?.adults.contains(adult) == true else { return }
        await perform(checkingPantryAccess: false) { start in
            let value = try await service.changeHouseholdPantryGrant(adult, enabled: !adult.enabled, session: session)
            try check(start)
            grants = value
        }
    }
}
