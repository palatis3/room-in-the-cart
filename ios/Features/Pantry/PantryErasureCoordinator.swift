import DeviceSurfaces
import Foundation
import CryptoKit
import Darwin
import CoreDomain
import LocalStore
import RecordArchive

/// An immutable user-reviewed SQL manifest and receipt-bound cleanup. Build a fresh
/// review after any basis change. A journal read on relaunch can only finish cleanup.
@MainActor final class PantryErasureCoordinator {
    typealias Selection = PantryErasureDependencies.Selection
    typealias CleanupHandler = @MainActor (Cleanup, InventoryErasureReceipt) async throws -> Void
    enum Failure: Error, Equatable { case unauthorized, stale, blocked, cleanupPending, invalid }
    enum Outcome: Equatable { case deleted, cleanupPending }
    enum Blocker: String, Hashable { case collateralPickups, ledgerHistory, unknownContent, recoveredRecords, retainedReceiptEvidence }
    struct Choice { let selection: Selection; let title: String }
    struct FileMark: Codable, Equatable { let name: String; let digest: Data }
    struct Cleanup: Codable, Equatable {
        let originID: UUID
        let wholeOrigin: Bool
        let pickupIDs: [UUID]
        let copyIDs: [UUID]
        let bundleIDs: [UUID]
        let files: [FileMark]
        var sharedReceipts: [SharedReceiptRetirement]? = nil
    }
    struct Basis: Codable, Equatable {
        let revision: Int64
        let token: InventorySourceToken
        let ledgerOrigin: UUID
        let ledgerRevision: Int64
        let ledgerDigest: Data?
        let registryGeneration: UUID
        let pending: [FileMark]
        var sharedReceipts: [SharedReceiptRetirement]? = nil
    }
    struct Review {
        let id: UUID
        let selection: Selection
        var sharedReceiptCount: Int = 0
        var aliasCount: Int = 0
        var receiptRevisionCount: Int = 0
        var priceRevisionCount: Int = 0
        let foodNames: [String]
        let pickupIDs: [UUID]
        let pickupTitles: [String]
        let collateralPickupIDs: [UUID]
        let collateralPickupTitles: [String]
        let retainedReceiptFoodNames: [String]
        let affectedReservationNames: [String]
        let copyIDs: [UUID]
        let pendingFileCount: Int
        let blockers: Set<Blocker>
        var canCommit: Bool { blockers.isEmpty }
        fileprivate let manifest: InventoryErasureManifest
        fileprivate let chunks: [InventoryErasureChunk]
        fileprivate let basis: Basis
        fileprivate let cleanup: Cleanup
        fileprivate let owner: UUID
    }

    private struct Journal: Codable {
        let version: Int
        let nonce: UUID
        let reviewDigest: Data
        let manifest: InventoryErasureManifest
        let cleanup: Cleanup
    }
    let inventory: ComparisonStore
    let ledger: LedgerStore
    let gate: PantryMutationGate
    let pendingDirectory: URL
    let registry: RecoveryRegistry
    let worker: PantryArchiveWorker
    let journalDirectory: URL
    let recoveredDirectory: URL?
    private weak var initiatingPresentation: (any PantryErasureObserver)?
    let receiptFilesForErasure: @MainActor (UUID, Date) async throws -> [SharedReceiptRetirement]
    let cleanupHandler: CleanupHandler
    let authorize: @MainActor () -> Bool
    let clock: () -> Date
    private let owner = UUID()

    init(inventory: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate, pendingDirectory: URL,
         registry: RecoveryRegistry, worker: PantryArchiveWorker, journalDirectory: URL,
         receiptFilesForErasure: @escaping @MainActor (UUID, Date) async throws -> [SharedReceiptRetirement] = { _, _ in [] },
         recoveredDirectory: URL? = nil, initiatingPresentation: (any PantryErasureObserver)? = nil, cleanup: @escaping CleanupHandler, authorize: @escaping @MainActor () -> Bool,
         clock: @escaping () -> Date = Date.init) {
        self.inventory = inventory; self.ledger = ledger; self.gate = gate; self.pendingDirectory = pendingDirectory
        self.registry = registry; self.worker = worker; self.journalDirectory = journalDirectory
        self.recoveredDirectory = recoveredDirectory
        self.receiptFilesForErasure = receiptFilesForErasure
        self.initiatingPresentation = initiatingPresentation
        cleanupHandler = cleanup; self.authorize = authorize; self.clock = clock
    }

    static func hasPendingCleanup(in directory: URL, originID: UUID) -> Bool {
        var info = stat()
        return lstat(marker(in: directory, originID: originID).path, &info) == 0 || errno != ENOENT
    }
    private static func marker(in directory: URL, originID: UUID) -> URL {
        directory.appendingPathComponent("pantry-erasure-" + originID.uuidString + ".json")
    }
    private var marker: URL { Self.marker(in: journalDirectory, originID: inventory.workspaceID) }
    func access() throws {
        try Task.checkCancellation()
        guard authorize() else { throw Failure.unauthorized }
    }
    private func idle() throws {
        guard !Self.hasPendingCleanup(in: journalDirectory, originID: inventory.workspaceID) else { throw Failure.cleanupPending }
    }

    func choices() async throws -> [Choice] {
        try access(); try idle()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let catalogue = try await catalogue()
        return catalogue.food + catalogue.pickups + catalogue.prices + [.init(selection: .wholeOrigin, title: "")]
    }

    private struct Catalogue {
        let state: InventoryState
        let token: InventorySourceToken
        var food: [Choice] = []
        var pickups: [Choice] = []
        var prices: [Choice] = []
        var reservationNames: [String] = []
    }
    /// Whole-origin retirement covers every row regardless of its schema. Use
    /// SQL identities even if a newer payload cannot supply a readable name.
    private func catalogue(includeReservations: Bool = false) async throws -> Catalogue {
        let state = try await inventory.inventoryState(); try access()
        guard state.active else { throw Failure.invalid }
        let token = try await inventory.inventorySourceToken(); try access()
        var result = Catalogue(state: state, token: token), cursor: UUID?
        for kind: InventoryRecordKind in includeReservations ? [.lot, .reservation] : [.lot] {
            cursor = nil
            while true {
                let page = try await inventory.inventoryRecords(kind: kind, after: cursor, limit: 50); try access()
                guard let last = page.last else { break }
                for row in page {
                    if kind == .lot {
                        result.food.append(.init(selection: .lot(row.key.id, revision: row.revision),
                            title: (try? PantryPersistenceCodec.lot(row).name) ?? row.key.id.uuidString))
                    } else { result.reservationNames.append((try? PantryPersistenceCodec.reservation(row).name) ?? row.key.id.uuidString) }
                }
                guard result.food.count + result.reservationNames.count <= 250_000 else { throw Failure.invalid }
                cursor = last.key.id
            }
        }
        var priceCursor: InventoryPriceRow?
        repeat {
            let page = try await inventory.priceRows(after: priceCursor, limit: 100)
            try access()
            for row in page {
                result.prices.append(.init(selection: .price(row.id, revision: row.revision),
                    title: (try? PantryPriceCodec.evidence(row).name) ?? row.id.uuidString))
            }
            guard result.prices.count <= 250_000 else { throw Failure.invalid }
            priceCursor = page.count == 100 ? page.last : nil
        } while priceCursor != nil
        cursor = nil
        while true {
            let page = try await inventory.inventorySourcePage(token: token, after: cursor, limit: 4); try access()
            guard let last = page.last else { break }
            result.pickups += page.map { .init(selection: .pickup($0.id, revision: $0.revision,
                payloadDigest: Self.digest($0.payload)), title: $0.title) }
            guard result.pickups.count <= 250_000 else { throw Failure.invalid }
            cursor = last.id
        }
        guard try await inventory.inventoryState() == state else { throw Failure.stale }; try access()
        guard try await inventory.inventorySourceToken() == token else { throw Failure.stale }; try access()
        return result
    }
    func prepare(_ selection: Selection) async throws -> Review {
        try access(); try idle()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        return try await prepare(selection, id: UUID())
    }

    private func prepare(_ selection: Selection, id: UUID) async throws -> Review {
        let date = clock()
        let impact = try await sqlImpact(selection, at: date)
        let whole = selection == .wholeOrigin
        let chunks = try Self.chunks(impact.entries)
        let chain = try chunks.reduce(InventoryErasureManifest.initialDigest) { try InventoryErasureManifest.appending($1, to: $0) }
        let inspection = try await external(rules: impact.rules, links: impact.links, expectedLedgers: impact.ledgerOrigins, at: date)
        let blockers = impact.blockers.union(inspection.blockers)
        let claimed = try await receiptFilesForErasure(inventory.workspaceID, date)
        try access()
        let affected = claimed.filter { (whole && $0.unclaimed != true) || impact.documentDigests.contains($0.fileDigest) }
        let cleanup = Cleanup(originID: inventory.workspaceID, wholeOrigin: whole, pickupIDs: impact.pickups.map(\.id),
            copyIDs: inspection.copies.map(\.id), bundleIDs: inspection.copies.map(\.bundleID), files: inspection.files, sharedReceipts: affected.isEmpty ? nil : affected)
        let basis = Basis(revision: impact.revision, token: impact.token, ledgerOrigin: ledger.workspaceID,
            ledgerRevision: inspection.ledgerRevision, ledgerDigest: inspection.ledgerDigest, registryGeneration: inspection.registryGeneration,
            pending: inspection.allFiles, sharedReceipts: claimed.isEmpty ? nil : claimed)
        let reviewDigest = try Self.reviewDigest(selection: selection, basis: basis)
        let operation = try Self.operationID(nonce: id, reviewDigest: reviewDigest, cleanup: cleanup, chain: chain)
        let price: InventoryErasureManifest.Price?
        if case .price(let id, let revision) = selection { price = .init(id: id, revision: revision) }
        else { price = nil }
        let manifest = InventoryErasureManifest(workspaceID: inventory.workspaceID, operationID: operation, expectedRevision: impact.revision,
            sourceToken: impact.token, scope: whole ? .origin : .sourceGraph, price: price, chunkCount: Int64(chunks.count),
            entryCount: Int64(impact.entries.count), manifestDigest: chain)
        try await verify(basis)
        return Review(id: id, selection: selection, sharedReceiptCount: affected.count, aliasCount: impact.aliasCount, receiptRevisionCount: impact.receiptRevisionCount, priceRevisionCount: impact.priceRevisionCount, foodNames: impact.foodNames,
            pickupIDs: cleanup.pickupIDs, pickupTitles: impact.pickups.map(\.title), collateralPickupIDs: impact.collateral.map(\.id),
            collateralPickupTitles: impact.collateral.map(\.title), retainedReceiptFoodNames: impact.retainedReceiptNames,
            affectedReservationNames: impact.affectedReservationNames,
            copyIDs: cleanup.copyIDs, pendingFileCount: cleanup.files.count, blockers: blockers,
            manifest: manifest, chunks: chunks, basis: basis, cleanup: cleanup, owner: owner)
    }

    private struct SQLImpact {
        var documentDigests: Set<String> = []
        let revision: Int64
        let token: InventorySourceToken
        let rules: PantryArchivePrivacyValidator.LocalRules
        let links: [PantryLegacyMigration.SourceLink]
        let ledgerOrigins: Set<UUID>
        let entries: [InventoryErasureEntry]
        let blockers: Set<Blocker>
        var aliasCount: Int = 0
        var receiptRevisionCount: Int = 0
        var priceRevisionCount: Int = 0
        let foodNames: [String]
        let pickups: [(id: UUID, title: String)]
        let collateral: [(id: UUID, title: String)]
        let retainedReceiptNames: [String]
        let affectedReservationNames: [String]
    }
    private func sqlImpact(_ selection: Selection, at date: Date) async throws -> SQLImpact {
        if case .price(let id, let revision) = selection {
            let state = try await inventory.inventoryState()
            try access()
            let token = try await inventory.inventorySourceToken()
            try access()
            guard state.active, try await inventory.priceRows(id: id, limit: 1).first?.revision == revision else { throw Failure.stale }
            try access()
            var rules = PantryArchivePrivacyValidator.LocalRules(origin: inventory.workspaceID, retiredOrigin: false)
            rules.prices = [id]
            let count = try await inventory.priceRevisionCount(for: id)
            try access()
            return SQLImpact(revision: state.revision, token: token, rules: rules, links: [], ledgerOrigins: [], entries: [],
                blockers: [], priceRevisionCount: count, foodNames: [], pickups: [], collateral: [], retainedReceiptNames: [],
                affectedReservationNames: [])
        }
        if selection == .wholeOrigin {
            let all = try await catalogue(includeReservations: true)
            let pickups = all.pickups.compactMap { choice -> (UUID, String)? in
                guard case .pickup(let id, _, _) = choice.selection else { return nil }
                return (id, choice.title)
            }
            let receipts = try await receiptImpact(lots: nil, pickups: [])
            return SQLImpact(documentDigests: receipts.digests, revision: all.state.revision, token: all.token,
                rules: .init(origin: inventory.workspaceID, retiredOrigin: true), links: [], ledgerOrigins: [], entries: [], blockers: [],
                aliasCount: try await inventory.receiptAliasCount(), receiptRevisionCount: receipts.count,
                priceRevisionCount: try await inventory.priceRevisionCount(), foodNames: all.food.map(\.title), pickups: pickups, collateral: [], retainedReceiptNames: [],
                affectedReservationNames: all.reservationNames)
        }
        let base = try await sourceBasis(at: date), context = base.context
        let scan = try await PantryErasureDependencies.scan(store: inventory, selection: selection, context: context, authorize: authorize)
        try access()
        let lots = scan.explicitlySelectedLotIDs.union(scan.pickupSourceCandidateLotIDs)
        let pickups: Set<UUID>
        switch selection {
        case .wholeOrigin: pickups = Set(base.heads.map(\.id))
        case .pickup(let id, _, _): pickups = [id]
        case .lot: pickups = []
        case .price: throw Failure.invalid
        }
        var blockers = Set<Blocker>()
        if !scan.sqlDependenciesVerified { blockers.insert(.unknownContent) }
        let receipts = try await receiptImpact(lots: lots, pickups: pickups)
        if !receipts.retainedLots.isEmpty { blockers.insert(.retainedReceiptEvidence) }
        if scan.needsExpandedReview { blockers.insert(.collateralPickups) }
        let foodReview = try InventoryPrivacyErasure.review(originID: context.originID, lots: context.lots, reservations: context.claims,
            erasingLots: lots, erasingReservations: [], at: date)
        let graph = try entries(scan: scan, context: context, review: foodReview, pickups: pickups)
        var rules = PantryArchivePrivacyValidator.LocalRules(origin: context.originID, retiredOrigin: false)
        rules.comparisons = pickups
        for entry in graph.entries {
            switch entry {
            case .record(let erase): rules.keys.insert(erase.key)
            case .reservation(let write): rules.floors[write.record.key.id] = write.expectedRevision
            case .comparison: break
            }
        }
        for food in context.lots where lots.contains(food.id) {
            rules.sources[context.originID, default: []].insert(try PantryPersistenceCodec.sourceIdentity(food.source).sourceID)
        }
        let titles = Dictionary(uniqueKeysWithValues: base.heads.map { ($0.id, $0.title) })
        func names(_ ids: Set<UUID>) -> [(UUID, String)] {
            ids.sorted { $0.uuidString < $1.uuidString }.map { ($0, titles[$0] ?? $0.uuidString) }
        }
        return SQLImpact(documentDigests: receipts.digests, revision: context.inventoryRevision, token: context.sourceToken, rules: rules,
            links: context.mapping.sourceLinks, ledgerOrigins: scan.ledgerOrigins, entries: graph.entries, blockers: blockers,
            aliasCount: try await inventory.receiptAliasCount(lotIDs: lots), receiptRevisionCount: receipts.count,
            priceRevisionCount: try await inventory.priceRevisionCount(lotIDs: lots), foodNames: context.lots.filter { lots.contains($0.id) }.map {
                lots.count > 1 ? $0.name + " · " + pantryLocationName($0.location) + " · " + String($0.id.uuidString.suffix(8)) : $0.name
            }, pickups: names(pickups), collateral: names(scan.collateralPickupIDs),
            retainedReceiptNames: context.lots.filter { scan.retainedReceiptLotIDsInCollateralPickups.contains($0.id) || receipts.retainedLots.contains($0.id) }.map(\.name),
            affectedReservationNames: context.claims.filter { graph.reservations.contains($0.id) }.map(\.name))
    }

    private func receiptImpact(lots: Set<UUID>?, pickups: Set<UUID>) async throws -> (count: Int, retainedLots: Set<UUID>, digests: Set<String>) {
        var cursor: UUID?, count = 0, retainedLots = Set<UUID>(), digests = Set<String>()
        while true {
            let page = try await inventory.acquisitionRows(after: cursor)
            try access()
            for row in page {
                let fact = try PantryAcquisitionCodec.record(row)
                if lots?.contains(fact.lotID) ?? true {
                    count += 1
                    if let digest = fact.imageDigest { digests.insert(digest.map { String(format: "%02x", $0) }.joined()) }
                }
                else if let source = fact.savedPickup, source.originID == inventory.workspaceID, pickups.contains(source.id) {
                    retainedLots.insert(fact.lotID)
                }
            }
            let affected = Set(page.map(\.lotID).filter { lots?.contains($0) ?? true })
            if !affected.isEmpty {
                digests.formUnion(try await inventory.rescanDocumentDigests(for: Array(affected)))
                try access()
            }
            guard let last = page.last else { break }
            cursor = last.id
        }
        return (count, retainedLots, digests)
    }

    private func sourceBasis(at date: Date) async throws -> (context: PantryErasureDependencies.Context, heads: [SavedComparison]) {
        let repository = PantryRepository(store: inventory, authorize: authorize)
        let snapshot = try await repository.load(at: date); try access()
        let token = try await inventory.inventorySourceToken(); try access()
        var heads: [SavedComparison] = [], cursor: UUID?, bytes = 0
        while true {
            let page = try await inventory.inventorySourcePage(token: token, after: cursor, limit: 4); try access()
            guard let last = page.last else { break }
            bytes += page.reduce(0) { $0 + $1.payload.count }
            guard heads.count + page.count <= PantryLegacyMigration.maximumHeads, bytes <= PantryLegacyMigration.maximumSourceBytes else { throw Failure.invalid }
            heads += page; cursor = last.id
        }
        let plan = try PantryLegacyMigration.map(originID: inventory.workspaceID, heads: heads.map(PantryLegacyMigration.SourceHead.init),
            ledger: .unavailable, at: date)
        return (try .init(snapshot: snapshot, mapping: plan, sourceToken: token, at: date), heads)
    }

    private func entries(scan: PantryErasureDependencies.Preview, context: PantryErasureDependencies.Context,
                         review: InventoryPrivacyErasure.Review, pickups: Set<UUID>) throws -> (entries: [InventoryErasureEntry], reservations: Set<UUID>) {
        guard scan.selection != .wholeOrigin else { return ([], []) }
        var revisions: [InventoryRecordKey: Int64] = [:]
        var changed = Dictionary(uniqueKeysWithValues: review.redactedReservations.map { ($0.id, $0) })
        let heads = Dictionary(uniqueKeysWithValues: context.claims.map { ($0.id, $0) })
        for inspection in scan.inspections where !inspection.matches.isEmpty {
            guard case .inventory(let key, let revision) = inspection.container else { continue }
            if key.kind == .reservation {
                if changed[key.id] == nil, let current = heads[key.id] {
                    guard current.revision < Int64.max else { throw Failure.invalid }
                    changed[key.id] = .init(id: current.id, originID: current.originID, revision: current.revision + 1,
                        foodID: current.foodID, lotID: current.lotID, name: current.name, amount: current.amount,
                        priority: current.priority, state: current.state, personal: current.personal)
                }
            } else {
                revisions[key] = max(revisions[key] ?? 0, revision)
            }
        }
        var entries = revisions.keys.sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }
            .map { InventoryErasureEntry.record(.init(key: $0, expectedRevision: revisions[$0]!)) }
        for claim in changed.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let row = InventoryRecord(key: .init(.reservation, claim.id), revision: claim.revision,
                payload: try ArchiveCodec.canonical(claim), lotID: claim.lotID)
            entries.append(.reservation(.init(record: row, expectedRevision: claim.revision - 1)))
        }
        for head in context.mapping.sourceHeads where pickups.contains(head.id) {
            entries.append(.comparison(id: head.id, expectedRevision: head.revision))
        }
        return (entries, Set(changed.keys))
    }

    private static func chunks(_ entries: [InventoryErasureEntry]) throws -> [InventoryErasureChunk] {
        var chunks: [InventoryErasureChunk] = [], pending: [InventoryErasureEntry] = [], size = 0
        for value in entries {
            let count = try ArchiveCodec.canonical(value).count
            if pending.count == 256 || size + count > 1_000_000 {
                chunks.append(.init(index: Int64(chunks.count), entries: pending)); pending = []; size = 0
            }
            pending.append(value); size += count
        }
        if !pending.isEmpty { chunks.append(.init(index: Int64(chunks.count), entries: pending)) }
        return chunks
    }

    func commit(_ review: Review) async throws -> Outcome {
        guard review.owner == owner, review.canCommit else { throw Failure.blocked }
        try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        try idle()
        // Reopen registered package bytes and repeat all external checks. A changed
        // effect list or manifest always requires a fresh visible confirmation.
        let current = try await prepare(review.selection, id: review.id)
        guard current.canCommit, current.basis == review.basis, current.cleanup == review.cleanup,
              current.manifest == review.manifest else { throw Failure.stale }
        let journal = Journal(version: 1, nonce: review.id,
            reviewDigest: try Self.reviewDigest(selection: review.selection, basis: review.basis), manifest: review.manifest, cleanup: review.cleanup)
        try PantryArchiveFiles.directory(journalDirectory, create: true)
        let journalBytes = try ArchiveCodec.canonical(journal), journalURL = marker
        try access()
        try await registry.beginPantryErasure(operationID: review.manifest.operationID, expectedGeneration: review.basis.registryGeneration) {
            try PantryArchiveFiles.write(journalBytes, to: journalURL)
        }
        let receipt: InventoryErasureReceipt
        do {
            try access()
            if review.cleanup.wholeOrigin {
                receipt = try await inventory.eraseInventoryOrigin(expectedRevision: review.basis.revision, sourceToken: review.basis.token,
                    operationID: review.manifest.operationID, at: clock())
            } else {
                _ = try await inventory.beginInventoryErasure(review.manifest)
                for chunk in review.chunks { try access(); _ = try await inventory.stageInventoryErasure(id: review.manifest.operationID, chunk: chunk) }
                try await verify(review.basis)
                try access()
                receipt = try await inventory.finishInventoryErasure(id: review.manifest.operationID, at: clock())
            }
        } catch {
            // Keep the journal when SQL status is uncertain. Recovery never
            // starts or finishes an uncommitted erasure under expired consent.
            if let outcome = try await recover(journal) { return outcome }
            throw error
        }
        return await finish(journal, receipt)
    }

    func recoverCleanup() async throws -> Outcome? {
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        guard Self.hasPendingCleanup(in: journalDirectory, originID: inventory.workspaceID) else { return nil }
        let bytes = try PantryArchiveFiles.read(marker, maximum: 32 * 1_048_576)
        let journal = try JSONDecoder().decode(Journal.self, from: bytes)
        guard journal.version == 1, journal.manifest.workspaceID == inventory.workspaceID, journal.cleanup.originID == inventory.workspaceID,
              journal.cleanup.wholeOrigin == (journal.manifest.scope == .origin), try ArchiveCodec.canonical(journal) == bytes else { throw Failure.invalid }
        return try await recover(journal)
    }
    private func recover(_ journal: Journal) async throws -> Outcome? {
        guard journal.reviewDigest.count == 32, journal.manifest.operationID == (try Self.operationID(
            nonce: journal.nonce, reviewDigest: journal.reviewDigest, cleanup: journal.cleanup, chain: journal.manifest.manifestDigest)) else { throw Failure.invalid }
        if let progress = try await inventory.inventoryErasureProgress(id: journal.manifest.operationID) {
            guard progress.manifest == journal.manifest else { throw Failure.invalid }
            if let receipt = progress.receipt { return await finish(journal, receipt) }
            if progress.status == .staging { _ = try await inventory.cancelInventoryErasure(id: journal.manifest.operationID) }
        }
        try await registry.cancelPantryErasure(operationID: journal.manifest.operationID)
        try FileManager.default.removeItem(at: marker)
        return nil
    }
    private func finish(_ journal: Journal, _ receipt: InventoryErasureReceipt) async -> Outcome {
        do {
            let cleanup = journal.cleanup
            guard receipt.scope == journal.manifest.scope, receipt.workspaceID == cleanup.originID,
                  receipt.operationID == journal.manifest.operationID, receipt.erasedRevision == journal.manifest.expectedRevision else { throw Failure.invalid }
            try await gate.invalidateForErasure(origin: cleanup.originID, initiator: initiatingPresentation)
            try await registry.registerErasedPantryBundles(Set(cleanup.bundleIDs), operationID: receipt.operationID)
            let pickupOrigin = "pickups/" + cleanup.originID.uuidString
            if cleanup.wholeOrigin { try await registry.registerErasedOrigins([cleanup.originID.uuidString, pickupOrigin]) }
            else {
                try await registry.registerErasedSources(cleanup.pickupIDs.map { .init(origin: pickupOrigin, recordID: $0.uuidString) })
            }
            try await cleanupHandler(cleanup, receipt)
            try removePending(cleanup.files)
            try FileManager.default.removeItem(at: marker)
            gate.erasureFinished(origin: cleanup.originID, initiator: initiatingPresentation)
            return .deleted
        } catch { return .cleanupPending }
    }
    private static func reviewDigest(selection: Selection, basis: Basis) throws -> Data {
        struct Binding: Encodable { let selection: Selection; let basis: Basis }
        return digest(try ArchiveCodec.canonical(Binding(selection: selection, basis: basis)))
    }
    /// The SQL receipt's operation ID authenticates the exact local cleanup set.
    /// A modified journal cannot use another completed SQL receipt as authority.
    private static func operationID(nonce: UUID, reviewDigest: Data, cleanup: Cleanup, chain: Data) throws -> UUID {
        struct Binding: Encodable { let nonce: UUID; let reviewDigest: Data; let cleanup: Cleanup; let chain: Data }
        let binding = Binding(nonce: nonce, reviewDigest: reviewDigest, cleanup: cleanup, chain: chain)
        var bytes = Array(digest(try ArchiveCodec.canonical(binding)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 128
        bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
