import Foundation
import Darwin
import CoreDomain
import LocalStore
import RecordArchive

extension PantryErasureCoordinator {
    struct External {
        let ledgerRevision: Int64
        let ledgerDigest: Data?
        let registryGeneration: UUID
        let copies: [RecoveredPantryCopy]
        let files: [FileMark]
        let allFiles: [FileMark]
        let blockers: Set<Blocker>
    }
    private struct LedgerDocument: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }

    func external(rules: PantryArchivePrivacyValidator.LocalRules, links: [PantryLegacyMigration.SourceLink],
                  expectedLedgers: Set<UUID>, at date: Date) async throws -> External {
        let head = try await ledger.load(); try access()
        let revision = head?.revision ?? 0
        var blockers = Set<Blocker>()
        if revision > 0 {
            for index in 1...revision {
                let history = try await ledger.inventoryErasureHistory(revision: index, expectedHead: revision); try access()
                let record = history.record
                if let binding = history.projection, binding.inventoryWorkspaceID == rules.origin,
                   rules.retiredOrigin || rules.comparisons.contains(binding.targetID) || rules.floors[binding.targetID] != nil ||
                   rules.keys.contains(where: { $0.id == binding.targetID }) {
                    blockers.insert(.ledgerHistory)
                }
                do {
                    try ArchiveCodec.preflight(record.payload, maximum: LedgerStore.maximumPayloadBytes)
                    let workspace = try LedgerModel.validatePayload(record.payload)
                    try PantryErasureDependencies.knownFields(LedgerDocument(workspace: workspace), bytes: record.payload)
                    try checkLedger(workspace, rules: rules, links: links)
                } catch PantryArchivePrivacyValidator.Failure.retired { blockers.insert(.ledgerHistory) }
                catch { blockers.insert(.unknownContent) }
            }
        }
        let basis = try await registry.pantryErasureBasis(); try access()
        for copy in basis.records where copy.record.kind == .ledger || copy.record.kind == .pickup {
            do {
                try RecordsNativeCodec.validate(copy.record)
                try rules.check(copy.record, pairedLedgerOrigin: ledger.workspaceID)
                // An edited legacy recovery owns an additional SQLite history.
                // Its immutable registry snapshot alone cannot prove independence.
                guard let recoveredDirectory, let id = UUID(uuidString: copy.id), copy.id == id.uuidString else {
                    blockers.insert(.recoveredRecords); continue
                }
                var info = stat()
                let folder = recoveredDirectory.appendingPathComponent(id.uuidString)
                if lstat(folder.path, &info) == 0 || errno != ENOENT { blockers.insert(.recoveredRecords) }
            } catch { blockers.insert(.recoveredRecords) }
        }
        var copies: [RecoveredPantryCopy] = []
        for copy in basis.pantry {
            let handle = try await worker.open(reference: .init(bundleID: copy.reference.bundleID, manifestDigest: copy.reference.manifestDigest))
            try access()
            guard handle.descriptor.originID == copy.reference.originID, handle.descriptor.inventoryRevision == copy.reference.inventoryRevision else { throw Failure.invalid }
            do { try await rules.check(handle, worker: worker) }
            catch PantryArchivePrivacyValidator.Failure.retired { copies.append(copy) }
            catch PantryArchivePrivacyValidator.Failure.unverifiable { blockers.insert(.unknownContent) }
            try access()
        }
        let origins = Set(try await ledger.retiredWorkspaceIDs()).union([ledger.workspaceID]); try access()
        if !expectedLedgers.isSubset(of: origins) { blockers.insert(.ledgerHistory) }
        let pending = try pendingFiles()
        var matching: [FileMark] = []
        for file in pending {
            do {
                let history = try pendingHistory(file, ledgerOrigins: origins)
                try PantryArchiveCodec.validateHistory(history, at: date)
                try rules.check(history)
            } catch PantryArchivePrivacyValidator.Failure.retired { matching.append(file) }
            catch { blockers.insert(.unknownContent) }
        }
        return External(ledgerRevision: revision, ledgerDigest: head.map { Self.digest($0.payload) }, registryGeneration: basis.generation,
            copies: copies, files: matching, allFiles: pending, blockers: blockers)
    }

    private func checkLedger(_ workspace: LedgerWorkspace, rules: PantryArchivePrivacyValidator.LocalRules,
                             links: [PantryLegacyMigration.SourceLink]) throws {
        for pack in workspace.packSelections {
            // An ordinary gross calculation in an independently owned shopping
            // list carries no pantry or pickup proof.
            if let origin = pack.canonicalStockEvidence?.basis.originID ?? pack.stockEvidence?.sourceWorkspaceID {
                try rules.pack(pack, origin)
            }
        }
        for shop in workspace.shops {
            for link in shop.mealOccurrences.compactMap(\.carryover) {
                try rules.journeyID(link.sourceShopID, rules.origin)
                try rules.legacyLot(link.sourceSupplyID, rules.origin)
                try rules.legacyLot(link.confirmedSupplyID, rules.origin)
                try rules.key(.reservation, link.reservationID, rules.origin)
                for source in links where source.references.contains(where: {
                    $0.legacyLotID == link.sourceSupplyID || $0.observationIDs.contains(link.sourceSupplyID) ||
                    $0.observationIDs.contains(link.confirmedSupplyID)
                }) { try rules.source(source.source) }
                // A carryover can survive removal of its physical receipt carrier.
                // An unmapped legacy supply is insufficient proof of independence.
                if !rules.sources.isEmpty && !links.contains(where: { source in
                    source.references.contains { $0.legacyLotID == link.sourceSupplyID ||
                        $0.observationIDs.contains(link.sourceSupplyID) || $0.observationIDs.contains(link.confirmedSupplyID) }
                }) { throw PantryArchivePrivacyValidator.Failure.unverifiable }
            }
        }
    }

    func verify(_ basis: Basis) async throws {
        try access()
        guard try await inventory.inventoryState().revision == basis.revision else { throw Failure.stale }; try access()
        guard try await inventory.inventorySourceToken() == basis.token else { throw Failure.stale }; try access()
        let head = try await ledger.load(); try access()
        guard ledger.workspaceID == basis.ledgerOrigin, (head?.revision ?? 0) == basis.ledgerRevision,
              head.map({ Self.digest($0.payload) }) == basis.ledgerDigest else { throw Failure.stale }
        let registryBasis = try await registry.pantryErasureBasis(); try access()
        guard registryBasis.generation == basis.registryGeneration, try pendingFiles() == basis.pending else { throw Failure.stale }
    }

    private var filePrefix: String { inventory.workspaceID.uuidString }
    private var maximumJournalBytes: Int {
        max(PantryPickupPendingStore.maximumFileBytes, PantryPackSelectionPendingStore.maximumFileBytes, PantryPendingStore.maximumFileBytes)
    }
    private func pendingFiles() throws -> [FileMark] {
        var info = stat()
        guard lstat(pendingDirectory.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw Failure.invalid
        }
        try PantryArchiveFiles.requireDirectory(pendingDirectory)
        var failed = false
        guard let listing = FileManager.default.enumerator(at: pendingDirectory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else { throw Failure.invalid }
        var marks: [FileMark] = []
        for case let url as URL in listing {
            let name = url.lastPathComponent
            guard name.lowercased().hasPrefix((filePrefix + ".").lowercased()) else { continue }
            if name.hasSuffix(".lock") {
                try PantryArchiveFiles.requireRegular(url)
                guard lstat(url.path, &info) == 0, info.st_size == 0 else { throw Failure.invalid }
                continue
            }
            guard marks.count < 10_000 else { throw Failure.invalid }
            marks.append(.init(name: name, digest: Self.digest(try PantryArchiveFiles.read(url, maximum: maximumJournalBytes))))
        }
        guard !failed else { throw Failure.invalid }
        return marks.sorted { $0.name < $1.name }
    }

    private func pendingHistory(_ mark: FileMark, ledgerOrigins: Set<UUID>) throws -> PantryArchiveCodec.History {
        let url = pendingDirectory.appendingPathComponent(mark.name)
        let bytes = try PantryArchiveFiles.read(url, maximum: maximumJournalBytes)
        guard Self.digest(bytes) == mark.digest else { throw Failure.stale }
        try ArchiveCodec.preflight(bytes, maximum: maximumJournalBytes)
        guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let body = envelope["entry"] else { throw Failure.invalid }
        let entryBytes = try JSONSerialization.data(withJSONObject: body)
        let origin = inventory.workspaceID
        if mark.name == filePrefix + ".food.json" {
            guard Set(envelope.keys) == ["version", "inventoryWorkspaceID", "entry", "digest"],
                  let entry = try PantryPendingStore.archiveEntry(at: url, inventoryWorkspaceID: origin) else { throw Failure.invalid }
            try PantryErasureDependencies.knownFields(entry, bytes: entryBytes)
            return .foodPending(entry)
        }
        guard Set(envelope.keys) == ["version", "inventoryWorkspaceID", "ledgerWorkspaceID", "entry", "digest"],
              let raw = envelope["ledgerWorkspaceID"] as? String, let ledgerID = UUID(uuidString: raw), ledgerOrigins.contains(ledgerID) else { throw Failure.invalid }
        if mark.name == filePrefix + ".json", let entry = try PantryPickupPendingStore.archiveEntry(at: url, inventoryWorkspaceID: origin, ledgerWorkspaceID: ledgerID) {
            try PantryErasureDependencies.knownFields(entry, bytes: entryBytes)
            return .pickupPending(entry)
        }
        guard mark.name == filePrefix + "." + ledgerID.uuidString + ".pack.json",
              let entry = try PantryPackSelectionPendingStore.archiveEntry(at: url, inventoryWorkspaceID: origin, ledgerWorkspaceID: ledgerID) else { throw Failure.invalid }
        try PantryErasureDependencies.knownFields(entry, bytes: entryBytes)
        return .packPending(entry)
    }

    func removePending(_ files: [FileMark]) throws {
        for mark in files {
            // The journal contains local fixed filenames only. Reject every path
            // component and verify the reviewed bytes under the writer's lock.
            guard mark.name.hasPrefix(filePrefix + "."), !mark.name.contains("/"), mark.name.hasSuffix(".json"),
                  mark.digest.count == 32 else { throw Failure.invalid }
            let url = pendingDirectory.appendingPathComponent(mark.name)
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT { continue }
            let lock = Darwin.open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw Failure.invalid }; defer { Darwin.close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw Failure.invalid }; defer { flock(lock, LOCK_UN) }
            if lstat(url.path, &info) != 0, errno == ENOENT { continue }
            guard Self.digest(try PantryArchiveFiles.read(url, maximum: maximumJournalBytes)) == mark.digest else { throw Failure.stale }
            try FileManager.default.removeItem(at: url)
        }
    }
}
