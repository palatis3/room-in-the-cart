import Foundation
import CoreDomain
import LocalStore

/// A bounded complete read. The consuming port owns the paired-store exclusive
/// lease across this read and its write; this helper deliberately never nests it.
@MainActor final class PantryCanonicalReader {
    enum Failure: Error { case unauthorized, capacity, inconsistentSnapshot }
    struct Read {
        let snapshot: PantryRepository.Snapshot
        let sources: [PantryLegacyMigration.SourceHead]
        let token: InventorySourceToken
    }
    private let store: ComparisonStore
    private let repository: PantryRepository
    private let authorize: () -> Bool
    init(store: ComparisonStore, limits: PantryRepository.ReadLimits = .standard, authorize: @escaping () -> Bool) {
        self.store = store; self.authorize = authorize
        repository = PantryRepository(store: store, limits: limits, authorize: authorize)
    }
    func load(at now: Date) async throws -> Read {
        try access()
        let snapshot = try await repository.load(at: now); try access()
        let token = try await store.inventorySourceToken(); try access()
        var sources: [PantryLegacyMigration.SourceHead] = [], cursor: UUID?, bytes = 0
        while true {
            let page = try await store.inventorySourcePage(token: token, after: cursor, limit: InventoryPersistenceLimits.pageItems)
            try access()
            bytes += page.reduce(0) { $0 + $1.payload.count }
            guard sources.count + page.count <= PantryLegacyMigration.maximumHeads,
                  bytes <= PantryLegacyMigration.maximumSourceBytes else { throw Failure.capacity }
            sources += page.map(PantryLegacyMigration.SourceHead.init)
            if page.count < InventoryPersistenceLimits.pageItems { break }
            cursor = page.last?.id
        }
        let read = Read(snapshot: snapshot, sources: sources, token: token)
        try await assertCurrent(read)
        return read
    }
    func assertCurrent(_ read: Read) async throws {
        try access()
        let state = try await store.inventoryState(); try access()
        let token = try await store.inventorySourceToken(); try access()
        guard state == read.snapshot.state, token == read.token else { throw Failure.inconsistentSnapshot }
    }
    private func access() throws { guard authorize() else { throw Failure.unauthorized } }
}
