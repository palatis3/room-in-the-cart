import Foundation
import CryptoKit
import Darwin
import CoreDomain
import LocalStore
import RecordArchive

/// A successful verifier alone constructs this handle. It proves file contents,
/// not current owner authorization; composition revalidates its own lease.
struct PantryArchiveHandle: Sendable {
    let reference: PantryArchiveStorage.Reference
    let descriptor: PantryArchiveCodec.Descriptor
    let scope: PantryArchiveWorker.Scope
    let lotCount: Int
    let reservationCount: Int
    let fileCount: Int
    let directory: URL
    fileprivate init(reference: PantryArchiveStorage.Reference, descriptor: PantryArchiveCodec.Descriptor,
                     scope: PantryArchiveWorker.Scope, lotCount: Int, reservationCount: Int, fileCount: Int, directory: URL) {
        self.reference = reference; self.descriptor = descriptor; self.scope = scope
        self.lotCount = lotCount; self.reservationCount = reservationCount; self.fileCount = fileCount; self.directory = directory
    }
}
struct PantryPreparedImport: Sendable {
    let handle: PantryArchiveHandle
    fileprivate let lease: PantryImportDirectory
    var reference: PantryRecoveryReference {
        .init(bundleID: handle.reference.bundleID, manifestDigest: handle.reference.manifestDigest,
              originID: handle.descriptor.originID, inventoryRevision: handle.descriptor.inventoryRevision)
    }
}

struct PantryEncryptedPackage: Sendable {
    let id: UUID
    let bundleID: UUID
    let url: URL
    fileprivate init(id: UUID, bundleID: UUID, url: URL) { self.id = id; self.bundleID = bundleID; self.url = url }
}

struct PantryRestorationHandle: Sendable {
    let context: PantryArchiveWorker.RestorationContext
    let source: PantryArchiveHandle
    let plan: InventoryMigrationPlan
    fileprivate let id: UUID
    fileprivate let directory: URL
    fileprivate init(context: PantryArchiveWorker.RestorationContext, source: PantryArchiveHandle,
                     plan: InventoryMigrationPlan, id: UUID, directory: URL) {
        self.context = context; self.source = source; self.plan = plan; self.id = id; self.directory = directory
    }
}

actor PantryArchiveWorker {
    enum Failure: Error, Equatable { case invalid, missing, conflict, io, unsupported }
    struct IndependentScope: Codable, Equatable, Sendable {
        let copyID: UUID
        let original: PantryArchiveStorage.Reference
        let originalOriginID: UUID
        let originID: UUID
        let inventoryRevision: Int64
        let restorationID: UUID
        let restoredAt: Date
        let capturedAt: Date
        let foodPendingDigest: Data?
    }
    enum Scope: Codable, Equatable, Sendable {
        case paired(PantryArchiveCapture.Scope)
        case independent(IndependentScope)
        var originID: UUID { switch self { case .paired(let value): value.inventoryOriginID; case .independent(let value): value.originID } }
        var inventoryRevision: Int64 { switch self { case .paired(let value): value.inventoryRevision; case .independent(let value): value.inventoryRevision } }
        var capturedAt: Date { switch self { case .paired(let value): value.capturedAt; case .independent(let value): value.capturedAt } }
    }
    enum Evidence: Codable, Equatable, Sendable {
        case current(PantryArchiveCapture.Evidence)
        case historical(originID: UUID, PantryArchiveCapture.Evidence)
        case previousScope(Scope)
    }
    struct ProjectionBinding: Sendable {
        let id: UUID
        let value: PantryLedgerProjectionPort.IntentBinding
    }
    private struct Header: Codable {
        let namespace: String
        let version: Int
        let archive: PantryArchiveCodec.Manifest
        let scope: Scope
        let evidencePageCount: Int
        let evidenceItemCount: Int
        let evidenceChainDigest: Data
    }
    private struct EvidencePage: Codable {
        let version: Int
        let bundleID: UUID
        let index: Int
        let items: [Evidence]
    }
    private final class Job {
        let id: UUID
        let bundleID: UUID
        let directory: URL
        let descriptor: PantryArchiveCodec.Descriptor
        let index: PantryArchiveIndex
        var items = 0
        var evidence = 0
        init(id: UUID, bundleID: UUID, directory: URL, descriptor: PantryArchiveCodec.Descriptor, index: PantryArchiveIndex) {
            self.id = id; self.bundleID = bundleID; self.directory = directory; self.descriptor = descriptor; self.index = index
        }
    }
    private let root: URL
    private var jobs: [UUID: Job] = [:]
    private var exports: [UUID: URL] = [:]
    private var restorations: [UUID: (directory: URL, hashes: [Data])] = [:]
    private static let namespace = "pantry-owner-files/v2"
    private static let archiveStart = digest(Data("pantry-owner-archive-chain/v1".utf8))
    private static let evidenceStart = digest(Data("pantry-owner-scope-chain/v2".utf8))

    init(root: URL) throws {
        guard root.isFileURL else { throw Failure.invalid }
        self.root = root.standardizedFileURL
        try PantryArchiveFiles.directory(self.root, create: true)
    }
    func begin(descriptor: PantryArchiveCodec.Descriptor, bundleID: UUID = UUID()) throws -> UUID {
        try PantryArchiveCodec.validateDescriptor(descriptor)
        let id = UUID(), directory = root.appendingPathComponent("job-" + id.uuidString, isDirectory: true)
        try PantryArchiveFiles.directory(directory, create: true)
        do {
            let index = try PantryArchiveIndex(url: directory.appendingPathComponent("index.sqlite"))
            try PantryArchiveFiles.protect(directory.appendingPathComponent("index.sqlite"), permissions: 0o600)
            jobs[id] = Job(id: id, bundleID: bundleID, directory: directory, descriptor: descriptor, index: index)
            return id
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func cancel(_ id: UUID) throws {
        guard let job = jobs.removeValue(forKey: id) else { return }
        try job.index.close(); try FileManager.default.removeItem(at: job.directory)
    }
    private func job(_ id: UUID) throws -> Job {
        try Task.checkCancellation()
        guard let job = jobs[id] else { throw Failure.missing }; return job
    }
    /// Bounded item bytes, used for journals, source heads and derived lineage.
    func append(_ bytes: Data, to id: UUID, deduplicateHistory: Bool = false) throws {
        let job = try job(id)
        try ArchiveCodec.preflight(bytes, maximum: PantryArchiveCodec.maximumChunkBytes)
        let item = try JSONDecoder().decode(PantryArchiveCodec.Item.self, from: bytes)
        guard try ArchiveCodec.canonical(item) == bytes else { throw Failure.invalid }
        if deduplicateHistory, case .historical = item, try job.index.containsHistory(item) { return }
        try job.index.append(item, ordinal: job.items, at: job.descriptor.capturedAt); job.items += 1
    }
    func appendRecords(_ records: [InventoryRecord], to id: UUID) throws {
        guard records.count <= InventoryPersistenceLimits.pageItems else { throw Failure.invalid }
        let job = try job(id)
        for row in records {
            try Task.checkCancellation()
            let item: PantryArchiveCodec.Item
            switch row.key.kind {
            case .lot:
                let value = try PantryPersistenceCodec.lot(row); try exactKeys(value, bytes: row.payload); item = .lot(value)
            case .observation:
                let value = try PantryPersistenceCodec.observation(row); try exactKeys(value, bytes: row.payload); item = .observation(value)
            case .reservation:
                let value = try PantryPersistenceCodec.reservation(row); try exactKeys(value, bytes: row.payload); item = .reservation(value)
            case .sourceLink:
                let value = try PantryPersistenceCodec.sourceLink(row); try exactKeys(value, bytes: row.payload); item = .sourceLink(value)
            case .event:
                let value = try JSONDecoder().decode(InventoryEvent.self, from: row.payload)
                guard row.revision == 1, row.payloadVersion == 1, row.source == nil,
                      row.key.id == value.id, row.lotID == value.lotID else { throw Failure.invalid }
                try exactKeys(value, bytes: row.payload); item = .event(value)
            case .intent:
                try classifyIntent(row, job: job); continue
            }
            try job.index.append(item, ordinal: job.items, at: job.descriptor.capturedAt); job.items += 1
        }
    }
    private func classifyIntent(_ row: InventoryRecord, job: Job) throws {
        try ArchiveCodec.preflight(row.payload, maximum: InventoryPersistenceLimits.recordBytes)
        guard let object = try JSONSerialization.jsonObject(with: row.payload) as? [String: Any] else { throw Failure.invalid }
        if object["namespace"] != nil {
            guard object["namespace"] as? String == "pantry-legacy-provenance/v1" else { throw Failure.unsupported }
            let decoded = try JSONDecoder().decode(PantryMigrationPackage.Envelope.self, from: row.payload)
            let value = try PantryMigrationPackage.provenance(row, migrationID: decoded.migrationID, originID: job.descriptor.originID)
            try exactKeys(value, bytes: row.payload)
            try job.index.append(.historical(.migration(value)), ordinal: job.items, at: job.descriptor.capturedAt); job.items += 1
        } else if object["binding"] != nil {
            let value = try PantryLedgerProjectionPort.archiveBinding(row)
            guard value.binding.inventoryWorkspaceID == job.descriptor.originID else { throw Failure.invalid }
            try exactKeys(value, bytes: row.payload)
            try job.index.putMetadata(kind: "binding", id: row.key.id.uuidString, bytes: ArchiveCodec.canonical(row))
        } else if object["decision"] != nil {
            let value = try JSONDecoder().decode(PantryLedgerProjectionPort.ReviewDisposition.self, from: row.payload)
            try job.index.putMetadata(kind: "disposition", id: value.sourceIntentID.uuidString, bytes: ArchiveCodec.canonical(row))
        } else { throw Failure.unsupported }
    }
    func projectionBindings(_ id: UUID, after: UUID? = nil, limit: Int = 100) throws -> [ProjectionBinding] {
        guard (1...200).contains(limit) else { throw Failure.invalid }
        let job = try job(id)
        var result: [ProjectionBinding] = []
        try job.index.forEachMetadata(kind: "binding", after: after?.uuidString, limit: limit) { _, data in
            let row = try JSONDecoder().decode(InventoryRecord.self, from: data)
            result.append(.init(id: row.key.id, value: try PantryLedgerProjectionPort.archiveBinding(row)))
        }
        return result
    }
    func completeProjection(_ id: UUID, intentID: UUID, receipt: LedgerInventoryProjectionReceipt?, retired: Bool) throws {
        let job = try job(id)
        guard let bytes = try job.index.metadata(kind: "binding", id: intentID.uuidString) else { throw Failure.invalid }
        let row = try JSONDecoder().decode(InventoryRecord.self, from: bytes), value = try PantryLedgerProjectionPort.archiveBinding(row)
        var disposition: PantryArchiveCodec.ProjectionDisposition?
        if let bytes = try job.index.metadata(kind: "disposition", id: intentID.uuidString) {
            let marker = try JSONDecoder().decode(InventoryRecord.self, from: bytes)
            let decoded = try PantryLedgerProjectionPort.archiveDisposition(marker, bindingRecord: row)
            try exactKeys(decoded, bytes: marker.payload)
            disposition = .init(recordID: marker.key.id, value: decoded)
        }
        guard !retired || receipt == nil else { throw Failure.invalid }
        let item = PantryArchiveCodec.Item.historical(.projection(.init(sourceIntentID: intentID, binding: value,
            needsReview: disposition, application: receipt.map(PantryArchiveCodec.ProjectionApplication.init))))
        try job.index.append(item, ordinal: job.items, at: job.descriptor.capturedAt); job.items += 1
        try appendEvidence(.current(.projection(sourceIntentID: intentID,
            status: retired ? .retiredLedgerOrigin : receipt == nil ? .unappliedAtCapture : .applied)), to: id)
    }
    func appendEvidence(_ evidence: Evidence, to id: UUID, deduplicate: Bool = false) throws {
        let job = try job(id)
        let bytes = try ArchiveCodec.canonical(evidence), fingerprint = ArchiveCodec.digest(bytes)
        if deduplicate, try job.index.metadata(kind: "appendedEvidence", id: fingerprint) != nil { return }
        if try job.index.metadata(kind: "appendedEvidence", id: fingerprint) == nil {
            try job.index.putMetadata(kind: "appendedEvidence", id: fingerprint, bytes: Data([1]))
        }
        try job.index.appendEvidence(bytes, ordinal: job.evidence); job.evidence += 1
    }
    private func exactKeys<T: Encodable>(_ value: T, bytes: Data) throws {
        guard let original = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary,
              let encoded = try JSONSerialization.jsonObject(with: ArchiveCodec.canonical(value)) as? NSDictionary,
              original == encoded else { throw Failure.invalid }
    }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    func finish(_ id: UUID, scope: Scope) throws -> PantryArchiveHandle {
        let job = try job(id)
        do {
            guard scope.originID == job.descriptor.originID, scope.inventoryRevision == job.descriptor.inventoryRevision,
                  scope.capturedAt == job.descriptor.capturedAt else { throw Failure.invalid }
            try job.index.validate(descriptor: job.descriptor)
            try validateScope(scope, index: job.index)
            let output = job.directory.appendingPathComponent("package", isDirectory: true)
            try PantryArchiveFiles.directory(output, create: true)
            var pending: [PantryArchiveCodec.Item] = [], bytes = 0, chunkCount = 0, chain = Self.archiveStart
            func flush() throws {
                guard !pending.isEmpty else { return }
                let chunk = PantryArchiveCodec.Chunk(namespace: PantryArchiveCodec.namespace, version: 1, bundleID: job.bundleID,
                    descriptor: job.descriptor, index: chunkCount, items: pending)
                let data = try PantryArchiveCodec.encodeChunk(chunk)
                try PantryArchiveFiles.write(data, to: output.appendingPathComponent(Self.chunkName(chunkCount)))
                chain = Self.next(chain, data); chunkCount += 1; pending = []; bytes = 0
            }
            try job.index.forEach { item in
                let size = try ArchiveCodec.canonical(item).count
                if pending.count == PantryArchiveCodec.maximumChunkItems || bytes + size + 2048 > PantryArchiveCodec.maximumChunkBytes { try flush() }
                pending.append(item); bytes += size + 1
            }
            try flush()
            var evidencePending: [Evidence] = [], evidenceIndex = 0, evidenceBytes = 0, evidenceChain = Self.evidenceStart
            func flushEvidence() throws {
                guard !evidencePending.isEmpty else { return }
                let page = EvidencePage(version: 2, bundleID: job.bundleID, index: evidenceIndex, items: evidencePending)
                let data = try ArchiveCodec.canonical(page)
                guard data.count <= PantryArchiveCodec.maximumChunkBytes else { throw Failure.invalid }
                try PantryArchiveFiles.write(data, to: output.appendingPathComponent(Self.scopeName(evidenceIndex)))
                evidenceChain = Self.next(evidenceChain, data); evidenceIndex += 1; evidencePending = []; evidenceBytes = 0
            }
            try job.index.forEachEvidence { data in
                if evidencePending.count == 256 || evidenceBytes + data.count + 2048 > PantryArchiveCodec.maximumChunkBytes { try flushEvidence() }
                evidencePending.append(try JSONDecoder().decode(Evidence.self, from: data)); evidenceBytes += data.count + 1
            }
            try flushEvidence()
            let manifest = PantryArchiveCodec.Manifest(namespace: PantryArchiveCodec.namespace, version: 1, bundleID: job.bundleID,
                descriptor: job.descriptor, chunkCount: chunkCount, itemCount: job.items, chainDigest: chain)
            let header = Header(namespace: Self.namespace, version: 2, archive: manifest, scope: scope,
                evidencePageCount: evidenceIndex, evidenceItemCount: job.evidence, evidenceChainDigest: evidenceChain)
            let data = try ArchiveCodec.canonical(header)
            guard data.count <= 16_384 else { throw Failure.invalid }
            try PantryArchiveFiles.write(data, to: output.appendingPathComponent("manifest.json"))
            let lots = try job.index.count("lot"), claims = try job.index.count("reservation")
            let target = root.appendingPathComponent(job.bundleID.uuidString, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.conflict }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: output, to: target)
            try cancel(id)
            return PantryArchiveHandle(reference: .init(bundleID: job.bundleID, manifestDigest: Self.digest(data)), descriptor: job.descriptor,
                scope: scope, lotCount: lots, reservationCount: claims, fileCount: 1 + chunkCount + evidenceIndex, directory: target)
        } catch { try? cancel(id); throw error }
    }
    /// Accepts an existing protected package only after re-reading every file and
    /// validating its complete graph. External references never mint handles.
    func open(reference: PantryArchiveStorage.Reference) throws -> PantryArchiveHandle {
        try verify(directory: root.appendingPathComponent(reference.bundleID.uuidString, isDirectory: true), expected: reference)
    }
    /// A generic recovered-copy deletion keeps its bundle ID in the local
    /// manifest. Reconcile any remaining bytes even after its Undo owner exits.
    func openDeletedBundleIfPresent(_ bundleID: UUID) throws -> PantryArchiveHandle? {
        let directory = root.appendingPathComponent(bundleID.uuidString, isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.io
        }
        let handle = try verify(directory: directory)
        guard handle.reference.bundleID == bundleID else { throw Failure.invalid }
        return handle
    }
    func verify(directory: URL, expected: PantryArchiveStorage.Reference? = nil) throws -> PantryArchiveHandle {
        try PantryArchiveFiles.directory(directory, create: false)
        let data = try PantryArchiveFiles.read(directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        let (header, legacy) = try Self.header(data)
        let reference = PantryArchiveStorage.Reference(bundleID: header.archive.bundleID, manifestDigest: Self.digest(data))
        guard expected == nil || expected == reference else { throw Failure.invalid }
        try Self.validateNames(directory, header: header)
        let id = try begin(descriptor: header.archive.descriptor, bundleID: header.archive.bundleID)
        do {
            let job = try job(id)
            var chain = Self.archiveStart
            for index in 0..<header.archive.chunkCount {
                try Task.checkCancellation()
                let bytes = try PantryArchiveFiles.read(directory.appendingPathComponent(Self.chunkName(index)), maximum: PantryArchiveCodec.maximumChunkBytes)
                let chunk = try PantryArchiveCodec.decodeChunk(bytes)
                guard chunk.index == index, chunk.bundleID == header.archive.bundleID, chunk.descriptor == header.archive.descriptor else { throw Failure.invalid }
                for item in chunk.items { try job.index.append(item, ordinal: job.items, at: job.descriptor.capturedAt); job.items += 1 }
                guard job.items <= header.archive.itemCount else { throw Failure.invalid }
                chain = Self.next(chain, bytes)
            }
            guard job.items == header.archive.itemCount, chain == header.archive.chainDigest else { throw Failure.invalid }
            var evidenceChain = legacy ? Self.digest(Data("pantry-owner-scope-chain/v1".utf8)) : Self.evidenceStart
            for index in 0..<header.evidencePageCount {
                let bytes = try PantryArchiveFiles.read(directory.appendingPathComponent(Self.scopeName(index)), maximum: PantryArchiveCodec.maximumChunkBytes)
                let items = try Self.decodeEvidence(bytes, legacy: legacy, bundleID: reference.bundleID, index: index)
                for item in items { try appendEvidence(item, to: id) }
                guard job.evidence <= header.evidenceItemCount else { throw Failure.invalid }
                evidenceChain = Self.next(evidenceChain, bytes)
            }
            guard job.evidence == header.evidenceItemCount, evidenceChain == header.evidenceChainDigest else { throw Failure.invalid }
            try job.index.validate(descriptor: job.descriptor); try validateScope(header.scope, index: job.index)
            let handle = PantryArchiveHandle(reference: reference, descriptor: job.descriptor, scope: header.scope,
                lotCount: try job.index.count("lot"), reservationCount: try job.index.count("reservation"),
                fileCount: 1 + header.archive.chunkCount + header.evidencePageCount, directory: directory)
            try cancel(id); return handle
        } catch { try? cancel(id); throw error }
    }
    private static func decodeEvidence(_ bytes: Data, legacy: Bool, bundleID: UUID, index: Int) throws -> [Evidence] {
        try ArchiveCodec.preflight(bytes, maximum: PantryArchiveCodec.maximumChunkBytes)
        let items: [Evidence]
        if legacy {
            let page = try JSONDecoder().decode(PantryArchiveStorage.EvidencePage.self, from: bytes)
            guard page.version == 1, page.bundleID == bundleID, page.index == index,
                  !page.items.isEmpty, page.items.count <= 256, try ArchiveCodec.canonical(page) == bytes else { throw Failure.invalid }
            items = page.items.map(Evidence.current)
        } else {
            let page = try JSONDecoder().decode(EvidencePage.self, from: bytes)
            guard page.version == 2, page.bundleID == bundleID, page.index == index,
                  !page.items.isEmpty, page.items.count <= 256, try ArchiveCodec.canonical(page) == bytes else { throw Failure.invalid }
            items = page.items
        }
        return items
    }
    private static func header(_ data: Data) throws -> (Header, Bool) {
        try ArchiveCodec.preflight(data, maximum: 16_384)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        let result: Header, legacy: Bool
        if value["namespace"] as? String == "pantry-owner-files/v1" {
            let old = try JSONDecoder().decode(PantryArchiveStorage.Header.self, from: data)
            guard old.version == 1, try ArchiveCodec.canonical(old) == data else { throw Failure.invalid }
            result = Header(namespace: namespace, version: 2, archive: old.archive, scope: .paired(old.scope),
                evidencePageCount: old.evidencePageCount, evidenceItemCount: old.evidenceItemCount, evidenceChainDigest: old.evidenceChainDigest)
            legacy = true
        } else {
            result = try JSONDecoder().decode(Header.self, from: data)
            guard result.namespace == namespace, result.version == 2, try ArchiveCodec.canonical(result) == data else { throw Failure.unsupported }
            legacy = false
        }
        _ = try PantryArchiveCodec.decodeManifest(ArchiveCodec.canonical(result.archive))
        guard result.evidencePageCount >= 0, result.evidenceItemCount >= result.evidencePageCount,
              (result.evidencePageCount == 0) == (result.evidenceItemCount == 0), result.evidenceChainDigest.count == 32,
              result.archive.chunkCount <= result.archive.itemCount,
              result.scope.originID == result.archive.descriptor.originID,
              result.scope.inventoryRevision == result.archive.descriptor.inventoryRevision,
              result.scope.capturedAt == result.archive.descriptor.capturedAt else { throw Failure.invalid }
        return (result, legacy)
    }
    private static func validateNames(_ directory: URL, header: Header) throws {
        let sum = header.archive.chunkCount.addingReportingOverflow(header.evidencePageCount)
        guard !sum.overflow, sum.partialValue < Int.max else { throw Failure.invalid }
        var count = 0
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { throw Failure.io }
        for case let file as URL in files {
            try PantryArchiveFiles.requireRegular(file)
            let name = file.lastPathComponent
            if name != "manifest.json" {
                if name.hasPrefix("pantry-"), name.hasSuffix(".json"), let index = Int(name.dropFirst(7).dropLast(5)),
                   index >= 0, index < header.archive.chunkCount, name == chunkName(index) { }
                else if name.hasPrefix("scope-"), name.hasSuffix(".json"), let index = Int(name.dropFirst(6).dropLast(5)),
                        index >= 0, index < header.evidencePageCount, name == scopeName(index) { }
                else { throw Failure.invalid }
            }
            count += 1
        }
        guard count == sum.partialValue + 1 else { throw Failure.invalid }
    }
    private static func chunkName(_ index: Int) -> String { "pantry-\(index).json" }
    private static func scopeName(_ index: Int) -> String { "scope-\(index).json" }
    private static func next(_ chain: Data, _ data: Data) -> Data { digest(chain + digest(data)) }

    private func validateScopeShape(_ scope: Scope) throws {
        guard scope.inventoryRevision >= 0, scope.capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalid }
        switch scope {
        case .paired(let value):
            guard value.version == 1, value.sourceToken.workspaceID == value.inventoryOriginID,
                  value.sourceToken.generation >= 0, value.sourceToken.digest.count == 32, value.ledgerRevision >= 0,
                  (value.ledgerRevision == 0) == (value.ledgerOperationID == nil),
                  (value.ledgerRevision == 0) == (value.ledgerPayloadDigest == nil),
                  value.ledgerPayloadDigest.map({ $0.count == 32 }) ?? true,
                  value.pendingDigest.map({ $0.count == 32 }) ?? true,
                  value.foodPendingDigest.map({ $0.count == 32 }) ?? true,
                  value.packPendingDigest.map({ $0.count == 32 }) ?? true else { throw Failure.invalid }
        case .independent(let value):
            guard value.originID != value.originalOriginID, value.original.manifestDigest.count == 32,
                  value.restoredAt.timeIntervalSinceReferenceDate.isFinite, value.restoredAt <= value.capturedAt,
                  value.foodPendingDigest.map({ $0.count == 32 }) ?? true else { throw Failure.invalid }
        }
    }
    private func validateScope(_ scope: Scope, index: PantryArchiveIndex) throws {
        try validateScopeShape(scope)
        var statuses = 0, projections = 0, previousScopeFound = false
        if case .paired(let value) = scope {
            try index.putMetadata(kind: "ledgerOrigin", id: value.ledgerOriginID.uuidString, bytes: Data([1]))
        }
        try index.forEachEvidence { bytes in
            let item = try JSONDecoder().decode(Evidence.self, from: bytes)
            try index.putMetadata(kind: "evidenceUnique", id: ArchiveCodec.digest(bytes), bytes: Data([1]))
            let evidence: PantryArchiveCapture.Evidence, origin: UUID, current: Bool
            switch item {
            case .current(let value): evidence = value; origin = scope.originID; current = true
            case .historical(let id, let value): evidence = value; origin = id; current = false
            case .previousScope(let value):
                try validateScopeShape(value)
                guard value.capturedAt <= scope.capturedAt else { throw Failure.invalid }
                if case .independent(let independent) = scope, value.originID == independent.originalOriginID { previousScopeFound = true }
                return
            }
            switch evidence {
            case let .inventoryRetired(_, id, revision, _): guard id == origin, revision > 0 else { throw Failure.invalid }
            case .reservationRedacted(let value):
                guard value.workspaceID == origin, value.throughRevision > 0 else { throw Failure.invalid }
                try index.putMetadata(kind: "redaction:" + origin.uuidString, id: value.reservationID.uuidString, bytes: ArchiveCodec.canonical(value))
                if current, case .reservation(let claim)? = try index.item(kind: "reservation", id: value.reservationID.uuidString) {
                    guard claim.revision > value.throughRevision else { throw Failure.invalid }
                }
            case let .sourceRetired(source, id, _):
                guard id == origin, (1...256).contains(source.sourceID.utf8.count) else { throw Failure.invalid }
            case let .comparisonRetired(_, id, revision, _, date):
                guard id == origin, revision > 0, date.timeIntervalSinceReferenceDate.isFinite, date <= scope.capturedAt else { throw Failure.invalid }
            case let .ledgerRetired(id, revision, replacement, _, date):
                guard id != replacement, revision >= 0, date.timeIntervalSinceReferenceDate.isFinite, date <= scope.capturedAt else { throw Failure.invalid }
                if current {
                    try index.putMetadata(kind: "ledgerOrigin", id: id.uuidString, bytes: Data([1]))
                    try index.putMetadata(kind: "retiredLedger", id: id.uuidString, bytes: Data([1]))
                }
            case let .projection(id, status):
                if current {
                    try index.putMetadata(kind: "projectionStatus", id: id.uuidString, bytes: ArchiveCodec.canonical(status)); statuses += 1
                }
            }
        }
        var pickupDigest: Data?, foodDigest: Data?, packCount = 0
        try index.forEach(kind: "history") { item in
            guard case .historical(let history) = item else { throw Failure.invalid }
            switch history {
            case .originalReservation(let value):
                if let bytes = try index.metadata(kind: "redaction:" + value.originID.uuidString, id: value.id.uuidString) {
                    let marker = try JSONDecoder().decode(InventoryReservationRedaction.self, from: bytes)
                    guard value.revision > marker.throughRevision else { throw Failure.invalid }
                }
            case .pickupPending(let value) where value.submission.request.originID == scope.originID:
                guard pickupDigest == nil, case .paired = scope else { throw Failure.invalid }
                pickupDigest = Self.digest(try ArchiveCodec.canonical(value))
            case .foodPending(let value) where value.command.originID == scope.originID:
                guard foodDigest == nil else { throw Failure.invalid }
                foodDigest = Self.digest(try ArchiveCodec.canonical(value))
            case .packPending(let value) where value.request.inventoryWorkspaceID == scope.originID:
                guard case .paired = scope, try index.metadata(kind: "ledgerOrigin", id: value.request.ledgerWorkspaceID.uuidString) != nil else { throw Failure.invalid }
                try index.putMetadata(kind: "packPending", id: value.request.ledgerWorkspaceID.uuidString, bytes: Self.digest(ArchiveCodec.canonical(value)))
                packCount += 1
            case .projection(let value) where value.binding.binding.inventoryWorkspaceID == scope.originID:
                guard case .paired(let paired) = scope,
                      let bytes = try index.metadata(kind: "projectionStatus", id: value.sourceIntentID.uuidString) else { throw Failure.invalid }
                let status = try JSONDecoder().decode(PantryArchiveCapture.ProjectionStatus.self, from: bytes)
                switch status {
                case .applied:
                    guard value.application != nil, value.binding.binding.ledgerWorkspaceID == paired.ledgerOriginID else { throw Failure.invalid }
                case .unappliedAtCapture:
                    guard value.application == nil, value.binding.binding.ledgerWorkspaceID == paired.ledgerOriginID else { throw Failure.invalid }
                case .retiredLedgerOrigin:
                    guard value.application == nil, try index.metadata(kind: "retiredLedger", id: value.binding.binding.ledgerWorkspaceID.uuidString) != nil else { throw Failure.invalid }
                }
                projections += 1
            default: break
            }
        }
        guard projections == statuses else { throw Failure.invalid }
        switch scope {
        case .paired(let value):
            guard pickupDigest == value.pendingDigest, foodDigest == value.foodPendingDigest else { throw Failure.invalid }
            if let expected = value.packPendingDigest {
                struct Pair: Encodable { let ledgerOriginID: UUID; let entryDigest: Data? }
                var hash = SHA256()
                hash.update(data: Data("{\"inventoryOriginID\":\"\(value.inventoryOriginID.uuidString)\",\"pairs\":[".utf8))
                var first = true
                try index.forEachMetadata(kind: "ledgerOrigin") { key, _ in
                    guard let id = UUID(uuidString: key) else { throw Failure.invalid }
                    if !first { hash.update(data: Data(",".utf8)) }; first = false
                    hash.update(data: try ArchiveCodec.canonical(Pair(ledgerOriginID: id, entryDigest: index.metadata(kind: "packPending", id: key))))
                }
                hash.update(data: Data("]}".utf8))
                guard Data(hash.finalize()) == expected else { throw Failure.invalid }
            } else { guard packCount == 0 else { throw Failure.invalid } }
        case .independent(let value):
            guard previousScopeFound, foodDigest == value.foodPendingDigest, pickupDigest == nil, packCount == 0 else { throw Failure.invalid }
        }
        // A retained review marker cannot be silently omitted because its binding disappeared.
        try index.forEachMetadata(kind: "disposition") { key, _ in
            guard try index.metadata(kind: "binding", id: key) != nil else { throw Failure.invalid }
        }
    }

    func encryptedExport(_ handle: PantryArchiveHandle, key: String) throws -> PantryEncryptedPackage {
        _ = try verify(directory: handle.directory, expected: handle.reference)
        let id = UUID(), directory = root.appendingPathComponent("export-" + id.uuidString + ".ritcpantry", isDirectory: true)
        try PantryArchiveFiles.directory(directory, create: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let manifest = try PantryArchiveFiles.read(handle.directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        guard Self.digest(manifest) == handle.reference.manifestDigest else { throw Failure.invalid }
        let (header, legacy) = try Self.header(manifest)
        func seal(_ bytes: Data, name: String) throws {
            try Task.checkCancellation()
            let encrypted = try PantryRecoveryEncryption.seal(bytes, context: .init(bundleID: handle.reference.bundleID, name: name), key: key)
            try PantryArchiveFiles.write(encrypted, to: directory.appendingPathComponent(name))
        }
        try seal(manifest, name: "manifest.json")
        var chain = Self.archiveStart
        for index in 0..<header.archive.chunkCount {
            let name = Self.chunkName(index)
            let bytes = try PantryArchiveFiles.read(handle.directory.appendingPathComponent(name), maximum: PantryArchiveCodec.maximumChunkBytes)
            chain = Self.next(chain, bytes); try seal(bytes, name: name)
        }
        guard chain == header.archive.chainDigest else { throw Failure.invalid }
        var evidenceChain = legacy ? Self.digest(Data("pantry-owner-scope-chain/v1".utf8)) : Self.evidenceStart
        for index in 0..<header.evidencePageCount {
            let name = Self.scopeName(index)
            let bytes = try PantryArchiveFiles.read(handle.directory.appendingPathComponent(name), maximum: PantryArchiveCodec.maximumChunkBytes)
            evidenceChain = Self.next(evidenceChain, bytes); try seal(bytes, name: name)
        }
        guard evidenceChain == header.evidenceChainDigest else { throw Failure.invalid }
        try Task.checkCancellation()
        exports[id] = directory; complete = true
        return PantryEncryptedPackage(id: id, bundleID: handle.reference.bundleID, url: directory)
    }
    func discardExport(_ package: PantryEncryptedPackage) throws {
        guard let owned = exports[package.id] else { return }
        guard owned == package.url else { throw Failure.invalid }
        try FileManager.default.removeItem(at: package.url); exports[package.id] = nil
    }
    func prepareImport(url: URL, key: String) async throws -> PantryPreparedImport {
        let lease = try PantryImportDirectory.create(in: root)
        do {
            try PantryArchiveFiles.directory(lease.payload, create: true)
            try await Self.coordinatedDecrypt(url: url, key: key, destination: lease.payload)
            try Task.checkCancellation()
            return PantryPreparedImport(handle: try verify(directory: lease.payload), lease: lease)
        } catch {
            try FileManager.default.removeItem(at: lease.directory)
            throw error
        }
    }

    func revalidateImport(_ prepared: PantryPreparedImport) throws -> PantryArchiveHandle {
        guard prepared.lease.directory.deletingLastPathComponent().standardizedFileURL.path == root.path else { throw Failure.invalid }
        return try verify(directory: prepared.lease.payload, expected: prepared.handle.reference)
    }

    func applyImport(_ prepared: PantryPreparedImport, review: PantryRecoveryReview,
                     registry: RecoveryRegistry, now: Date,
                     authorize: @MainActor @Sendable () -> Bool = { true }) async throws -> RecoveredPantryCopy {
        guard prepared.reference == review.reference,
              prepared.lease.directory.deletingLastPathComponent().standardizedFileURL.path == root.path else { throw Failure.invalid }
        let lease = prepared.lease, reference = prepared.reference
        let destination = root.appendingPathComponent(reference.bundleID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try verify(directory: destination, expected: prepared.handle.reference)
        }
        let bytes = try ArchiveCodec.canonical(reference)
        if FileManager.default.fileExists(atPath: lease.marker.path) {
            guard try PantryArchiveFiles.read(lease.marker, maximum: 4096) == bytes else { throw Failure.invalid }
        } else {
            try PantryArchiveFiles.write(bytes, to: lease.marker)
        }
        // The registry owns ordering across instances. Only a checked, durable
        // reference may be installed. The marker survives a process exit between
        // the registry write and the directory rename.
        try Task.checkCancellation()
        guard await authorize() else { throw ArchiveError.unavailable }
        return try await registry.applyPantry(review, now: now) {
            try Self.install(lease, reference: reference, destination: destination)
        }
    }

    private nonisolated static func install(_ lease: PantryImportDirectory, reference: PantryRecoveryReference,
                                            destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try PantryArchiveFiles.requireDirectory(destination)
            let manifest = try PantryArchiveFiles.read(destination.appendingPathComponent("manifest.json"), maximum: 16_384)
            guard Data(SHA256.hash(data: manifest)) == reference.manifestDigest else { throw Failure.conflict }
        } else {
            try FileManager.default.moveItem(at: lease.payload, to: destination)
        }
    }

    func discardImport(_ prepared: PantryPreparedImport, registry: RecoveryRegistry) async throws {
        guard prepared.lease.directory.deletingLastPathComponent().standardizedFileURL.path == root.path else { throw Failure.invalid }
        try await finishImportDirectory(prepared.lease, registry: registry)
    }

    func reconcilePreparedImports(registry: RecoveryRegistry, requireIdle: Bool = false) async throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for entry in entries where PantryImportDirectory.ownsName(entry.lastPathComponent) {
            guard let abandoned = try PantryImportDirectory.abandoned(entry, root: root) else {
                if requireIdle && FileManager.default.fileExists(atPath: entry.path) { throw Failure.conflict }
                continue
            }
            try await finishImportDirectory(abandoned, registry: registry)
        }
    }

    private func finishImportDirectory(_ lease: PantryImportDirectory, registry: RecoveryRegistry) async throws {
        guard FileManager.default.fileExists(atPath: lease.directory.path) else { return }
        if FileManager.default.fileExists(atPath: lease.marker.path) {
            let bytes = try PantryArchiveFiles.read(lease.marker, maximum: 4096)
            let reference = try JSONDecoder().decode(PantryRecoveryReference.self, from: bytes)
            let destination = root.appendingPathComponent(reference.bundleID.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: lease.payload.path),
               try await registry.reviewPantry(reference).disposition == .identical {
                let handle = try verify(directory: lease.payload,
                    expected: .init(bundleID: reference.bundleID, manifestDigest: reference.manifestDigest))
                guard handle.descriptor.originID == reference.originID,
                      handle.descriptor.inventoryRevision == reference.inventoryRevision else { throw Failure.invalid }
                try await registry.finishRegisteredPantryFiles(reference) {
                    try Self.install(lease, reference: reference, destination: destination)
                }
            }
        }
        try FileManager.default.removeItem(at: lease.directory)
    }
    private nonisolated static func coordinatedDecrypt(url: URL, key: String, destination: URL) async throws {
        guard url.isFileURL else { throw Failure.invalid }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        let queue = OperationQueue(); queue.qualityOfService = .userInitiated; queue.maxConcurrentOperationCount = 1
        let cancellation = PantryArchiveCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSFileCoordinator().coordinate(with: [intent], queue: queue) { error in
                    guard error == nil else { continuation.resume(throwing: Failure.io); return }
                    continuation.resume(with: Result {
                        try cancellation.check()
                        // Do not set attributes on a user-selected external package.
                        try PantryArchiveFiles.requireDirectory(intent.url)
                        let encryptedManifest = try PantryArchiveFiles.read(intent.url.appendingPathComponent("manifest.json"), maximum: PantryRecoveryEncryption.maximumEncryptedBytes)
                        let context = try PantryRecoveryEncryption.context(in: encryptedManifest)
                        guard context.name == "manifest.json" else { throw Failure.invalid }
                        let manifest = try PantryRecoveryEncryption.open(encryptedManifest, context: context, key: key)
                        let (header, _) = try Self.header(manifest)
                        guard header.archive.bundleID == context.bundleID else { throw Failure.invalid }
                        try Self.validateNames(intent.url, header: header)
                        try PantryArchiveFiles.write(manifest, to: destination.appendingPathComponent("manifest.json"))
                        guard let files = FileManager.default.enumerator(at: intent.url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { throw Failure.io }
                        for case let file as URL in files where file.lastPathComponent != "manifest.json" {
                            try cancellation.check()
                            let encrypted = try PantryArchiveFiles.read(file, maximum: PantryRecoveryEncryption.maximumEncryptedBytes)
                            let bytes = try PantryRecoveryEncryption.open(encrypted,
                                context: .init(bundleID: context.bundleID, name: file.lastPathComponent), key: key)
                            try PantryArchiveFiles.write(bytes, to: destination.appendingPathComponent(file.lastPathComponent))
                        }
                        try cancellation.check()
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Copies all original lineage into the new self-contained package. It never
    /// reinstalls old bindings, journals, commands or receipts in the live store.
    func appendIndependentLineage(_ original: PantryArchiveHandle, scope: IndependentScope, to id: UUID) throws {
        let job = try job(id)
        guard scope.original == original.reference, scope.originalOriginID == original.descriptor.originID,
              scope.originID == job.descriptor.originID, scope.originID != original.descriptor.originID,
              scope.restoredAt >= original.descriptor.capturedAt else { throw Failure.invalid }
        _ = try verify(directory: original.directory, expected: original.reference)
        let manifestBytes = try PantryArchiveFiles.read(original.directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        guard Self.digest(manifestBytes) == original.reference.manifestDigest else { throw Failure.invalid }
        let (header, legacy) = try Self.header(manifestBytes)
        func history(_ value: PantryArchiveCodec.History) throws {
            try append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(value)), to: id, deduplicateHistory: true)
        }
        var consumedChain = Self.archiveStart
        for index in 0..<header.archive.chunkCount {
            let bytes = try PantryArchiveFiles.read(original.directory.appendingPathComponent(Self.chunkName(index)), maximum: PantryArchiveCodec.maximumChunkBytes)
            consumedChain = Self.next(consumedChain, bytes)
            let chunk = try PantryArchiveCodec.decodeChunk(bytes)
            for item in chunk.items {
                try Task.checkCancellation()
                switch item {
                case .lot(let value):
                    try history(.originalLot(value))
                    try history(.originalLot(PantryArchiveRestore.baselineLot(value, newOriginID: scope.originID, restorationID: scope.restorationID)))
                case .observation(let value): try history(.originalObservation(originID: original.descriptor.originID, value))
                case .event(let value): try history(.originalEvent(value))
                case .reservation(let value): try history(.originalReservation(value))
                case .sourceLink(let value): try history(.originalSourceLink(value))
                case .historical(let value): try history(value)
                }
            }
        }
        guard consumedChain == header.archive.chainDigest else { throw Failure.invalid }
        try history(.restoredFrom(original.descriptor))
        try appendEvidence(.previousScope(original.scope), to: id, deduplicate: true)
        var consumedEvidence = legacy ? Self.digest(Data("pantry-owner-scope-chain/v1".utf8)) : Self.evidenceStart
        for index in 0..<header.evidencePageCount {
            let bytes = try PantryArchiveFiles.read(original.directory.appendingPathComponent(Self.scopeName(index)), maximum: PantryArchiveCodec.maximumChunkBytes)
            consumedEvidence = Self.next(consumedEvidence, bytes)
            let items: [Evidence]
            if legacy {
                items = try JSONDecoder().decode(PantryArchiveStorage.EvidencePage.self, from: bytes).items.map(Evidence.current)
            } else { items = try JSONDecoder().decode(EvidencePage.self, from: bytes).items }
            for item in items {
                if case .current(let value) = item {
                    try appendEvidence(.historical(originID: original.descriptor.originID, value), to: id, deduplicate: true)
                } else { try appendEvidence(item, to: id, deduplicate: true) }
            }
        }
        guard consumedEvidence == header.evidenceChainDigest else { throw Failure.invalid }
    }
    struct Dependency: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case lot, observation, event, reservation, sourceLink, sourceHead, intent, ledgerOrigin, inventoryOrigin, price }
        let originID: UUID
        let kind: Kind
        let id: UUID
        let revision: Int64?
    }
    struct DependencyCursor: Codable, Equatable, Sendable { let chunk: Int; let item: Int; let detail: Int }
    struct DependencyPage: Sendable { let values: [Dependency]; let next: DependencyCursor? }
    /// Bounded dependency pages for local erasure reconciliation. Imported facts
    /// remain inert; only the caller's local erasure authority decides removal.
    func dependencies(_ handle: PantryArchiveHandle, after: DependencyCursor? = nil, limit: Int = 200) throws -> DependencyPage {
        guard (1...200).contains(limit) else { throw Failure.invalid }
        let bytes = try PantryArchiveFiles.read(handle.directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        guard Self.digest(bytes) == handle.reference.manifestDigest else { throw Failure.invalid }
        let (header, _) = try Self.header(bytes)
        let cursor = after ?? .init(chunk: 0, item: 0, detail: 0)
        guard cursor.chunk >= 0, cursor.chunk <= header.archive.chunkCount, cursor.item >= 0, cursor.detail >= 0 else { throw Failure.invalid }
        var result: [Dependency] = [], next: DependencyCursor?, chain = Self.archiveStart
        // Authenticate the exact consumed chain. This bounded read favors integrity
        // over a persistent second registry/index; it never trusts mutable URLs.
        for ordinal in 0..<header.archive.chunkCount {
            try Task.checkCancellation()
            let data = try PantryArchiveFiles.read(handle.directory.appendingPathComponent(Self.chunkName(ordinal)), maximum: PantryArchiveCodec.maximumChunkBytes)
            chain = Self.next(chain, data)
            let chunk = try PantryArchiveCodec.decodeChunk(data)
            guard chunk.index == ordinal, chunk.bundleID == handle.reference.bundleID, chunk.descriptor == handle.descriptor else { throw Failure.invalid }
            if ordinal < cursor.chunk { continue }
            let start = ordinal == cursor.chunk ? cursor.item : 0
            guard start <= chunk.items.count else { throw Failure.invalid }
            for item in start..<chunk.items.count {
                let values = try Self.dependencies(chunk.items[item], originID: handle.descriptor.originID)
                let detail = ordinal == cursor.chunk && item == cursor.item ? cursor.detail : 0
                guard detail <= values.count else { throw Failure.invalid }
                for offset in detail..<values.count {
                    if result.count < limit { result.append(values[offset]) }
                    else if next == nil { next = .init(chunk: ordinal, item: item, detail: offset) }
                }
            }
        }
        guard chain == header.archive.chainDigest else { throw Failure.invalid }
        return .init(values: result, next: next)
    }
    private static func dependencies(_ item: PantryArchiveCodec.Item, originID: UUID) throws -> [Dependency] {
        func entry(_ origin: UUID, _ kind: Dependency.Kind, _ id: UUID, _ revision: Int64? = nil) -> Dependency {
            .init(originID: origin, kind: kind, id: id, revision: revision)
        }
        switch item {
        case .lot(let value): return [entry(value.source.originID, .lot, value.id, value.revision)]
        case .observation(let value): return [entry(originID, .observation, value.id), entry(originID, .lot, value.lotID)]
        case .event(let value): return [entry(value.originID, .event, value.id), entry(value.originID, .lot, value.lotID)]
        case .reservation(let value): return [entry(value.originID, .reservation, value.id, value.revision)]
        case .sourceLink(let value): return [entry(value.source.originID, .sourceLink, value.lotID), entry(value.source.originID, .lot, value.lotID)]
        case .historical(let value):
            switch value {
            case .price(let origin, let price):
                var dependencies = [entry(origin, .price, price.id, price.revision)]
                if let lot = price.linkedLotID { dependencies.append(entry(origin, .lot, lot)) }
                return dependencies
            case .acquisition(let origin, let row):
                var dependencies = [entry(origin, .lot, row.lotID)]
                if let pickup = row.savedPickup { dependencies.append(entry(pickup.originID, .sourceHead, pickup.id)) }
                return dependencies
            case .originalLot(let value): return [entry(value.source.originID, .lot, value.id, value.revision)]
            case .originalObservation(let origin, let value): return [entry(origin, .observation, value.id), entry(origin, .lot, value.lotID)]
            case .originalEvent(let value): return [entry(value.originID, .event, value.id), entry(value.originID, .lot, value.lotID)]
            case .originalReservation(let value): return [entry(value.originID, .reservation, value.id, value.revision)]
            case .originalSourceLink(let value): return [entry(value.source.originID, .sourceLink, value.lotID)]
            case .restoredFrom(let value): return [entry(value.originID, .inventoryOrigin, value.originID)]
            case .sourceHead(let origin, let value): return [entry(origin, .sourceHead, value.id, value.revision)]
            case .foodPending(let value):
                var result = value.commands.map { entry($0.originID, .lot, $0.lotID) }
                if case .reservation(let edit) = value.command.change {
                    result.append(entry(value.command.originID, .reservation, edit.id, max(1, edit.previousRevision)))
                }
                return result
            case .pickupPending(let value):
                var result = value.submission.changedHeads.map { entry(value.submission.request.originID, .sourceHead, $0.id, $0.revision) }
                if let ledger = value.submission.request.ledgerOriginID { result.append(entry(ledger, .ledgerOrigin, ledger)) }
                return result
            case .packPending(let value): return [entry(value.request.ledgerWorkspaceID, .ledgerOrigin, value.request.ledgerWorkspaceID), entry(value.request.inventoryWorkspaceID, .inventoryOrigin, value.request.inventoryWorkspaceID)]
            case .projection(let value): return [entry(value.binding.binding.inventoryWorkspaceID, .intent, value.sourceIntentID, 1), entry(value.binding.binding.ledgerWorkspaceID, .ledgerOrigin, value.binding.binding.ledgerWorkspaceID)]
            case .migration(let value):
                switch value.body {
                case .originalLot(let lot, _): return [entry(value.originID, .lot, lot.id, lot.revision)]
                case .originalObservation(let observation, _): return [entry(value.originID, .observation, observation.id), entry(value.originID, .lot, observation.lotID)]
                case .sourceHead(let head): return [entry(value.originID, .sourceHead, head.id, head.revision)]
                case .claimLink(let id, _, let journey): return [entry(value.originID, .reservation, id), entry(value.originID, .sourceHead, journey)]
                default: return [entry(value.originID, .inventoryOrigin, value.originID)]
                }
            }
        }
    }

    struct RestorationContext: Codable, Equatable, Sendable {
        let version: Int
        let copyID: UUID
        let reference: PantryArchiveStorage.Reference
        let workspaceID: UUID
        let restorationID: UUID
        let preparedAt: Date
    }
    func prepareRestoration(source: PantryArchiveHandle, context: RestorationContext,
                            sourceToken: InventorySourceToken) throws -> PantryRestorationHandle {
        guard context.version == 1, context.reference == source.reference,
              context.workspaceID != source.descriptor.originID, sourceToken.workspaceID == context.workspaceID,
              context.preparedAt.timeIntervalSinceReferenceDate.isFinite, context.preparedAt >= source.descriptor.capturedAt else { throw Failure.invalid }
        _ = try verify(directory: source.directory, expected: source.reference)
        if case .paired(let paired) = source.scope, paired.ledgerOriginID == context.workspaceID { throw Failure.invalid }
        let id = UUID(), directory = root.appendingPathComponent("restore-" + id.uuidString, isDirectory: true)
        try PantryArchiveFiles.directory(directory, create: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let manifestBytes = try PantryArchiveFiles.read(source.directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        guard Self.digest(manifestBytes) == source.reference.manifestDigest else { throw Failure.invalid }
        let (header, _) = try Self.header(manifestBytes)
        let index = try PantryArchiveIndex(url: directory.appendingPathComponent("rows.sqlite"))
        defer { try? index.close() }
        try PantryArchiveFiles.protect(directory.appendingPathComponent("rows.sqlite"), permissions: 0o600)
        var prices: [InventoryPriceRow] = []
        var acquisitions: [InventoryAcquisitionRow] = []
        var pending: [InventoryRecord] = [], size = 0, chunkIndex = 0, count = 0, hashes: [Data] = []
        var chain = InventoryMigrationManifest.initialDigest
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func flush() throws {
            guard !pending.isEmpty || !acquisitions.isEmpty || !prices.isEmpty else { return }
            let chunk = InventoryMigrationChunk(index: chunkIndex, records: pending, acquisitions: acquisitions, prices: prices)
            chain = try InventoryMigrationManifest.appending(chunk, to: chain)
            let bytes = try encoder.encode(chunk)
            guard bytes.count <= InventoryPersistenceLimits.batchBytes else { throw Failure.invalid }
            try PantryArchiveFiles.write(bytes, to: directory.appendingPathComponent("migration-\(chunkIndex).json"))
            hashes.append(Self.digest(bytes))
            chunkIndex += 1; count += pending.count + acquisitions.count + prices.count; pending = []; acquisitions = []; prices = []; size = 0
        }
        func append(_ record: InventoryRecord) throws {
            guard record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalid }
            let bytes = try encoder.encode(record).count
            if pending.count == InventoryPersistenceLimits.batchItems || size + bytes + 2048 > InventoryPersistenceLimits.batchBytes { try flush() }
            pending.append(record); size += bytes + 1
        }
        func stage(_ record: InventoryRecord) throws {
            try index.putMetadata(kind: "restoration", id: record.key.kind.rawValue + "/" + record.key.id.uuidString,
                bytes: ArchiveCodec.canonical(record))
        }
        var consumedChain = Self.archiveStart
        for ordinal in 0..<header.archive.chunkCount {
            let bytes = try PantryArchiveFiles.read(source.directory.appendingPathComponent(Self.chunkName(ordinal)), maximum: PantryArchiveCodec.maximumChunkBytes)
            consumedChain = Self.next(consumedChain, bytes)
            let chunk = try PantryArchiveCodec.decodeChunk(bytes)
            for item in chunk.items {
                try Task.checkCancellation()
                guard !(try Self.dependencies(item, originID: source.descriptor.originID)).contains(where: { $0.originID == context.workspaceID }) else { throw Failure.invalid }
                switch item {
                case .historical(.price(let origin, let fact)) where origin == source.descriptor.originID:
                    let row = try PantryPriceCodec.row(fact)
                    try index.putMetadata(kind: "priceRestoration", id: row.id.uuidString + "/" + String(row.revision), bytes: encoder.encode(row))
                case .historical(.acquisition(let origin, let fact)) where origin == source.descriptor.originID:
                    let row = try PantryAcquisitionCodec.row(fact)
                    try index.putMetadata(kind: "receiptRestoration", id: row.id.uuidString, bytes: encoder.encode(row))
                case .lot(let original):
                    let lot = try PantryArchiveRestore.baselineLot(original, newOriginID: context.workspaceID, restorationID: context.restorationID)
                    let observation = InventoryObservation(id: lot.observationID, lotID: lot.id, operationID: context.restorationID,
                        revision: 1, supersedesID: nil, observedAt: lot.confirmedAt, count: lot.count, countWording: lot.countWording)
                    let link = PantryPersistenceCodec.SourceLink(lotID: lot.id, source: lot.source)
                    try stage(.init(key: .init(.lot, lot.id), revision: 1, payload: ArchiveCodec.canonical(lot)))
                    try stage(.init(key: .init(.observation, observation.id), revision: 1, payload: ArchiveCodec.canonical(observation), lotID: lot.id))
                    try stage(.init(key: .init(.sourceLink, lot.id), revision: 1, payload: ArchiveCodec.canonical(link),
                        lotID: lot.id, source: PantryPersistenceCodec.sourceIdentity(lot.source)))
                case .reservation(let original):
                    let claim = InventoryReservation(id: original.id, originID: context.workspaceID, revision: 1,
                        foodID: original.foodID, lotID: original.lotID, name: original.name, amount: original.amount,
                        priority: original.priority, state: original.state == .released ? .released : .unresolved, personal: original.personal)
                    try claim.validate()
                    try stage(.init(key: .init(.reservation, claim.id), revision: 1,
                        payload: ArchiveCodec.canonical(claim), lotID: claim.lotID))
                default: break
                }
            }
        }
        guard consumedChain == header.archive.chainDigest else { throw Failure.invalid }
        try index.forEachMetadata(kind: "restoration") { _, bytes in
            try append(JSONDecoder().decode(InventoryRecord.self, from: bytes))
        }
        try flush()
        try index.forEachMetadata(kind: "receiptRestoration") { _, bytes in
            if acquisitions.count == InventoryPersistenceLimits.batchItems || size + bytes.count + 2048 > InventoryPersistenceLimits.batchBytes { try flush() }
            acquisitions.append(try JSONDecoder().decode(InventoryAcquisitionRow.self, from: bytes))
            size += bytes.count + 1
        }
        try flush()
        try index.forEachMetadata(kind: "priceRestoration") { _, bytes in
            if prices.count == InventoryPersistenceLimits.batchItems || size + bytes.count + 2048 > InventoryPersistenceLimits.batchBytes { try flush() }
            prices.append(try JSONDecoder().decode(InventoryPriceRow.self, from: bytes))
            size += bytes.count + 1
        }
        try flush(); try Task.checkCancellation()
        _ = try verify(directory: source.directory, expected: source.reference)
        let plan = InventoryMigrationPlan(migrationID: context.restorationID, workspaceID: context.workspaceID, expectedRevision: 0,
            sourceToken: sourceToken, reviewContext: try ArchiveCodec.canonical(context), expectedChunkCount: chunkIndex,
            expectedRecordCount: count, manifestDigest: chain)
        try PantryArchiveFiles.write(ArchiveCodec.canonical(plan), to: directory.appendingPathComponent("plan.json"))
        try index.close()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("rows.sqlite"))
        restorations[id] = (directory, hashes); complete = true
        return PantryRestorationHandle(context: context, source: source, plan: plan, id: id, directory: directory)
    }
    func restorationChunk(_ handle: PantryRestorationHandle, index: Int) throws -> InventoryMigrationChunk {
        guard let owned = restorations[handle.id], owned.directory == handle.directory,
              index >= 0, index < handle.plan.expectedChunkCount, index < owned.hashes.count else { throw Failure.invalid }
        let bytes = try PantryArchiveFiles.read(handle.directory.appendingPathComponent("migration-\(index).json"), maximum: InventoryPersistenceLimits.batchBytes)
        guard Self.digest(bytes) == owned.hashes[index] else { throw Failure.invalid }
        let chunk = try JSONDecoder().decode(InventoryMigrationChunk.self, from: bytes)
        guard chunk.index == index else { throw Failure.invalid }
        _ = try InventoryMigrationManifest.appending(chunk, to: InventoryMigrationManifest.initialDigest)
        return chunk
    }
    func discardRestoration(_ handle: PantryRestorationHandle) throws {
        guard let owned = restorations[handle.id] else { return }
        guard owned.directory == handle.directory else { throw Failure.invalid }
        if FileManager.default.fileExists(atPath: handle.directory.path) { try FileManager.default.removeItem(at: handle.directory) }
        restorations[handle.id] = nil
    }

}

extension PantryArchiveWorker {
    struct JournalDigests: Equatable, Sendable {
        let pickup: Data?
        let food: Data?
        let pack: Data?
    }
    private struct JournalDigest: Codable { let digest: Data? }
    private struct PackDigestPair: Encodable { let ledgerOriginID: UUID; let entryDigest: Data? }

    func registerLedgerOrigin(_ origin: UUID, retired: Bool, to id: UUID) throws {
        let index = try job(id).index
        guard try index.metadata(kind: "captureLedger", id: origin.uuidString) == nil else { throw Failure.invalid }
        try index.putMetadata(kind: "captureLedger", id: origin.uuidString, bytes: Data([retired ? 1 : 0]))
    }
    func isRetiredLedger(_ origin: UUID, in id: UUID) throws -> Bool {
        guard let value = try job(id).index.metadata(kind: "captureLedger", id: origin.uuidString) else { throw Failure.invalid }
        return value == Data([1])
    }
    /// Reads one bounded journal at a time on this worker's executor. The second
    /// pass verifies both absent and present files, including every retired pair.
    func captureJournals(to id: UUID, directory: URL, pickupLedgerID: UUID?, revalidate: Bool = false) throws -> JournalDigests {
        let job = try job(id), origin = job.descriptor.originID
        try PantryArchiveFiles.directory(directory, create: true)
        func record(_ name: String, item: PantryArchiveCodec.Item?) throws -> Data? {
            let bytes = try item.map(ArchiveCodec.canonical)
            let entryDigest: Data?
            if let item {
                switch item {
                case .historical(.pickupPending(let value)): entryDigest = Self.digest(try ArchiveCodec.canonical(value))
                case .historical(.foodPending(let value)): entryDigest = Self.digest(try ArchiveCodec.canonical(value))
                case .historical(.packPending(let value)): entryDigest = Self.digest(try ArchiveCodec.canonical(value))
                default: throw Failure.invalid
                }
            } else { entryDigest = nil }
            let marker = try ArchiveCodec.canonical(JournalDigest(digest: entryDigest))
            if revalidate {
                guard try job.index.metadata(kind: "journal", id: name) == marker else { throw Failure.conflict }
            } else {
                try job.index.putMetadata(kind: "journal", id: name, bytes: marker)
                if let bytes { try append(bytes, to: id) }
            }
            return entryDigest
        }
        func checkFile(_ url: URL) throws {
            // A missing expected journal is valid. All existing inputs must be regular files.
            if FileManager.default.fileExists(atPath: url.path) { try PantryArchiveFiles.requireRegular(url) }
        }
        let foodURL = directory.appendingPathComponent("\(origin.uuidString).food.json")
        try checkFile(foodURL)
        let food = try PantryPendingStore.archiveEntry(at: foodURL, inventoryWorkspaceID: origin)
        let foodDigest = try record("food", item: food.map { .historical(.foodPending($0)) })
        var pickupDigest: Data?, packDigest: Data?
        if let pickupLedgerID {
            guard try job.index.metadata(kind: "captureLedger", id: pickupLedgerID.uuidString) != nil else { throw Failure.invalid }
            let pickupURL = directory.appendingPathComponent("\(origin.uuidString).json")
            try checkFile(pickupURL)
            let pickup = try PantryPickupPendingStore.archiveEntry(at: pickupURL, inventoryWorkspaceID: origin, ledgerWorkspaceID: pickupLedgerID)
            pickupDigest = try record("pickup", item: pickup.map { .historical(.pickupPending($0)) })
            var hash = SHA256()
            hash.update(data: Data("{\"inventoryOriginID\":\"\(origin.uuidString)\",\"pairs\":[".utf8))
            var first = true
            try job.index.forEachMetadata(kind: "captureLedger") { key, _ in
                try Task.checkCancellation()
                guard let ledgerID = UUID(uuidString: key) else { throw Failure.invalid }
                let url = directory.appendingPathComponent("\(origin.uuidString).\(key).pack.json")
                try checkFile(url)
                let value = try PantryPackSelectionPendingStore.archiveEntry(at: url, inventoryWorkspaceID: origin, ledgerWorkspaceID: ledgerID)
                let digest = try record(key, item: value.map { .historical(.packPending($0)) })
                if !first { hash.update(data: Data(",".utf8)) }; first = false
                hash.update(data: try ArchiveCodec.canonical(PackDigestPair(ledgerOriginID: ledgerID, entryDigest: digest)))
            }
            hash.update(data: Data("]}".utf8)); packDigest = Data(hash.finalize())
        }
        // Detect unknown pair files instead of omitting them; no global directory array.
        var failed = false
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else { throw Failure.io }
        let prefix = origin.uuidString + "."
        for case let url as URL in files {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            if name.lowercased().hasPrefix(prefix.lowercased()), name.lowercased().hasSuffix(".pack.json") {
                try PantryArchiveFiles.requireRegular(url)
                let raw = String(name.dropFirst(prefix.count).dropLast(10))
                guard pickupLedgerID != nil, let ledgerID = UUID(uuidString: raw), raw == ledgerID.uuidString,
                      name == "\(prefix)\(raw).pack.json",
                      try job.index.metadata(kind: "captureLedger", id: raw) != nil else { throw Failure.invalid }
            }
            if pickupLedgerID == nil, name == "\(origin.uuidString).json" { throw Failure.invalid }
        }
        guard !failed else { throw Failure.io }
        return .init(pickup: pickupDigest, food: foodDigest, pack: packDigest)
    }

    /// Only removes this worker's still-unregistered capture result. The caller owns
    /// registry/lifetime authorization and must never use this for a registered copy.
    func removePermanentlyRetiredBundles(_ retired: Set<UUID>) throws {
        guard !retired.isEmpty else { return }
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent), retired.contains(id) else { continue }
            try PantryArchiveFiles.directory(url, create: false)
            try manager.removeItem(at: url)
        }
    }

    func discardUnregistered(_ handle: PantryArchiveHandle) throws {
        let expected = root.appendingPathComponent(handle.reference.bundleID.uuidString, isDirectory: true)
        guard expected.standardizedFileURL == handle.directory.standardizedFileURL else { throw Failure.invalid }
        guard FileManager.default.fileExists(atPath: expected.path) else { return }
        let data = try PantryArchiveFiles.read(expected.appendingPathComponent("manifest.json"), maximum: 16_384)
        guard Self.digest(data) == handle.reference.manifestDigest else { throw Failure.conflict }
        try FileManager.default.removeItem(at: expected)
    }
}

extension PantryArchiveWorker {
    func ledgerDigest(_ record: LedgerRecord?, at date: Date) throws -> Data? {
        guard let record else { return nil }
        guard record.savedAt <= date else { throw Failure.invalid }
        _ = try LedgerModel.validatePayload(record.payload)
        return Self.digest(record.payload)
    }
    func appendRetainedRevisions(_ records: [InventoryRecord], to id: UUID) throws {
        guard records.count <= 200 else { throw Failure.invalid }
        let job = try job(id)
        for record in records {
            let history: PantryArchiveCodec.History
            switch record.key.kind {
            case .lot:
                let value = try PantryPersistenceCodec.lot(record); try exactKeys(value, bytes: record.payload)
                guard case .lot(let head)? = try job.index.item(kind: "lot", id: value.id.uuidString), value.revision <= head.revision else { throw Failure.invalid }
                if value.revision == head.revision { guard value == head else { throw Failure.invalid }; continue }
                history = .originalLot(value)
            case .reservation:
                let value = try PantryPersistenceCodec.reservation(record); try exactKeys(value, bytes: record.payload)
                guard case .reservation(let head)? = try job.index.item(kind: "reservation", id: value.id.uuidString), value.revision <= head.revision else { throw Failure.invalid }
                if value.revision == head.revision { guard value == head else { throw Failure.invalid }; continue }
                history = .originalReservation(value)
            default: continue // Other record kinds are immutable and already included as heads.
            }
            try append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(history)), to: id, deduplicateHistory: true)
        }
    }
    func appendSources(_ records: [SavedComparison], originID: UUID, to id: UUID) throws {
        guard records.count <= 200 else { throw Failure.invalid }
        for record in records {
            try append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(.sourceHead(originID: originID, .init(record)))),
                to: id, deduplicateHistory: true)
        }
    }
}

extension PantryArchiveWorker {
    enum Content: Sendable {
        /// Decode with PantryArchiveCodec.Item; all unknown cases fail its decoder.
        case item(Data)
        /// Decode with PantryArchiveWorker.Evidence, including historical scopes.
        case evidence(Data)
    }
    struct ContentCursor: Equatable, Sendable { let part: Int; let item: Int }
    struct ContentPage: Sendable { let values: [Content]; let next: ContentCursor? }

    private enum ContentPart {
        case items([PantryArchiveCodec.Item])
        case evidence([Evidence])

        var count: Int {
            switch self {
            case .items(let values): return values.count
            case .evidence(let values): return values.count
            }
        }
        func encoded(at index: Int) throws -> (Content, Int) {
            switch self {
            case .items(let values):
                let bytes = try ArchiveCodec.canonical(values[index])
                return (.item(bytes), bytes.count)
            case .evidence(let values):
                let bytes = try ArchiveCodec.canonical(values[index])
                return (.evidence(bytes), bytes.count)
            }
        }
    }

    /// The consumer sees one bounded part at a time. Only successful return
    /// authenticates the entire traversal, so callers keep their results private.
    @discardableResult private func readContent(_ handle: PantryArchiveHandle,
                                                _ consume: (Int, ContentPart) throws -> Void) throws -> Int {
        let manifest = try PantryArchiveFiles.read(handle.directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        guard Self.digest(manifest) == handle.reference.manifestDigest else { throw Failure.invalid }
        let (header, legacy) = try Self.header(manifest)
        let total = header.archive.chunkCount.addingReportingOverflow(header.evidencePageCount)
        guard !total.overflow, header.archive.bundleID == handle.reference.bundleID,
              header.archive.descriptor == handle.descriptor, header.scope == handle.scope else { throw Failure.invalid }

        var chain = Self.archiveStart
        var count = 0
        for index in 0..<header.archive.chunkCount {
            try Task.checkCancellation()
            let bytes = try PantryArchiveFiles.read(handle.directory.appendingPathComponent(Self.chunkName(index)),
                                                    maximum: PantryArchiveCodec.maximumChunkBytes)
            let chunk = try PantryArchiveCodec.decodeChunk(bytes)
            guard chunk.index == index, chunk.bundleID == handle.reference.bundleID, chunk.descriptor == handle.descriptor,
                  chunk.items.count <= header.archive.itemCount - count else { throw Failure.invalid }
            chain = Self.next(chain, bytes)
            count += chunk.items.count
            try consume(index, .items(chunk.items))
        }
        guard chain == header.archive.chainDigest, count == header.archive.itemCount else { throw Failure.invalid }
        chain = legacy ? Self.digest(Data("pantry-owner-scope-chain/v1".utf8)) : Self.evidenceStart
        count = 0
        for index in 0..<header.evidencePageCount {
            try Task.checkCancellation()
            let bytes = try PantryArchiveFiles.read(handle.directory.appendingPathComponent(Self.scopeName(index)),
                                                    maximum: PantryArchiveCodec.maximumChunkBytes)
            let values = try Self.decodeEvidence(bytes, legacy: legacy, bundleID: handle.reference.bundleID, index: index)
            guard values.count <= header.evidenceItemCount - count else { throw Failure.invalid }
            chain = Self.next(chain, bytes)
            count += values.count
            try consume(header.archive.chunkCount + index, .evidence(values))
        }
        guard chain == header.evidenceChainDigest, count == header.evidenceItemCount else { throw Failure.invalid }
        return total.partialValue
    }

    /// Restored history is read from the authenticated package. A prior origin belongs
    /// to this batch only when its final head reproduces the child's actual restore baseline.
    func archivedActions(_ handle: PantryArchiveHandle, context: RestorationContext, lot: InventoryLot) throws -> PantryArchivedActions {
        guard context.version == 1, context.reference == handle.reference, context.workspaceID == lot.source.originID,
              context.workspaceID != handle.scope.originID else { throw Failure.invalid }
        var scopes = [handle.scope.originID: handle.scope]
        var latest = [UUID: InventoryLot](), baselines = [UUID: InventoryLot]()
        var sourceLot: InventoryLot?
        try readContent(handle) { _, part in
            switch part {
            case .evidence(let evidence):
                for case .previousScope(let previous) in evidence {
                    if let prior = scopes[previous.originID], prior != previous { throw Failure.invalid }
                    scopes[previous.originID] = previous
                }
            case .items(let items):
                for item in items {
                    switch item {
                    case .lot(let head) where head.id == lot.id: sourceLot = head
                    case .historical(.originalLot(let head)) where head.id == lot.id:
                        let origin = head.source.originID
                        if head.revision == 1 {
                            if let saved = baselines[origin], saved != head { throw Failure.invalid }
                            baselines[origin] = head
                        }
                        if let old = latest[origin], old.revision > head.revision { continue }
                        if let old = latest[origin], old.revision == head.revision, old != head { throw Failure.invalid }
                        latest[origin] = head
                    default: break
                    }
                }
            }
        }
        guard let sourceLot,
              try PantryArchiveRestore.baselineLot(sourceLot, newOriginID: context.workspaceID,
                                                   restorationID: context.restorationID).source == lot.source else { return .init(usage: [], discards: []) }
        var lineage = [handle.scope.originID: sourceLot]
        var scope = handle.scope
        while case .independent(let copy) = scope {
            guard let parent = scopes[copy.originalOriginID], let head = latest[parent.originID],
                  let baseline = baselines[scope.originID], parent.capturedAt <= copy.restoredAt, head.updatedAt <= parent.capturedAt,
                  head.revision <= parent.inventoryRevision,
                  try PantryArchiveRestore.baselineLot(head, newOriginID: copy.originID, restorationID: copy.restorationID) == baseline
            else { break } // A new batch in the independent workspace has no earlier source.
            guard lineage[parent.originID] == nil else { throw Failure.invalid }
            lineage[parent.originID] = head
            scope = parent
        }

        let limits = PantryRepository.ReadLimits.standard
        var retainedBytes = 0, cookRows = 0
        func charge(_ item: PantryArchiveCodec.Item) throws {
            retainedBytes += try ArchiveCodec.canonical(item).count
            guard retainedBytes <= limits.payloadBytes else { throw InventoryError.capacity }
        }
        var observations = [UUID: [UUID: InventoryObservation]]()
        var events = [UUID: [InventoryEvent]]()
        struct CookHead { let revision: Int64; let rows: [PantryUsageHistoryRow] }
        var journeys = [UUID: CookHead](), retiredJourneys = [UUID: Int64]()
        try readContent(handle) { _, part in
            switch part {
            case .items(let items):
                for item in items {
                    switch item {
                    case .observation(let observation) where observation.lotID == lot.id:
                        try charge(item)
                        observations[handle.scope.originID, default: [:]][observation.id] = observation
                    case .historical(.originalObservation(let origin, let observation)) where observation.lotID == lot.id && lineage[origin] != nil:
                        try charge(item)
                        observations[origin, default: [:]][observation.id] = observation
                    case .event(let event) where event.lotID == lot.id,
                         .historical(.originalEvent(let event)) where event.lotID == lot.id:
                        if lineage[event.originID] != nil, case .revise(let revision) = event.change, revision.usage != nil || revision.portion != nil {
                            try charge(item)
                            events[event.originID, default: []].append(event)
                        }
                    case .historical(.sourceHead(let origin, let head)) where origin == scope.originID:
                        // Independent workspaces have no live cook journey. Only the final paired
                        // ancestor's latest surviving head can establish a cook, its corrections or Undo.
                        guard case .paired(let paired) = scope, head.savedAt <= paired.capturedAt,
                              journeys[head.id].map({ head.revision > $0.revision }) ?? true else { continue }
                        let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
                        guard journey.id == head.id, journey.savedAt == head.savedAt else { throw Failure.invalid }
                        try PickupModel.validate(journey)
                        var rows = [PantryUsageHistoryRow]()
                        for cook in journey.cookedMeals ?? [] where cook.isActive {
                            guard cook.draft.inventoryID == origin, cook.draft.ledgerID == paired.ledgerOriginID,
                                  cook.draft.inventoryRevision < paired.inventoryRevision,
                                  cook.resolutions?.last.map({ $0.inventoryRevision < paired.inventoryRevision }) ?? true
                            else { continue }
                            rows += try cook.usageHistory(for: lot.id)
                        }
                        cookRows += rows.count - (journeys[head.id]?.rows.count ?? 0)
                        journeys[head.id] = .init(revision: head.revision, rows: rows)
                        guard journeys.count <= PantryLegacyMigration.maximumHeads, cookRows <= limits.observations else {
                            throw InventoryError.capacity
                        }
                    default: break
                    }
                }
            case .evidence(let values):
                for value in values {
                    let evidence: PantryArchiveCapture.Evidence
                    switch value {
                    case .current(let e) where handle.scope.originID == scope.originID: evidence = e
                    case .historical(let origin, let e) where origin == scope.originID: evidence = e
                    default: continue
                    }
                    if case .comparisonRetired(let id, let origin, let revision, _, _) = evidence, origin == scope.originID {
                        retiredJourneys[id] = max(revision, retiredJourneys[id] ?? 0)
                    }
                }
            }
        }
        var rows = journeys.filter { $0.value.revision > (retiredJourneys[$0.key] ?? 0) }.flatMap { $0.value.rows }
        var discards: [PantryDiscardRow] = [], undone = Set<UUID>()
        for (origin, uses) in events {
            guard let head = lineage[origin], let readings = observations[origin] else { throw Failure.invalid }
            var chain = Set<UUID>(), cursor: UUID? = head.observationID
            while let id = cursor {
                guard chain.insert(id).inserted, let observation = readings[id] else { throw Failure.invalid }
                cursor = observation.supersedesID
            }
            for event in uses {
                guard case .revise(let revision) = event.change, let reading = revision.observation,
                      chain.contains(reading.observationID), let recorded = readings[reading.observationID],
                      recorded.operationID == event.operationID, recorded.revision == event.revision,
                      recorded.count == reading.count, recorded.countWording == reading.countWording,
                      recorded.observedAt == reading.observedAt, event.occurredAt <= head.updatedAt else { throw Failure.invalid }
                rows += try PantryUsageHistoryRow.entries(from: event)
                switch revision.portion {
                case let .discard(amount, reason):
                    discards.append(.init(id: event.id, lotID: lot.id, date: event.occurredAt, amount: amount, reason: reason))
                case .undoDiscard(let id): undone.insert(id)
                default: break
                }
            }
        }
        guard Set(rows.map(\.id)).count == rows.count, Set(discards.map(\.id)).count == discards.count else { throw Failure.invalid }
        return .init(usage: rows.sorted { ($0.occurredAt, $0.id.uuidString) > ($1.occurredAt, $1.id.uuidString) },
                     discards: discards.filter { !undone.contains($0.id) })
    }

    /// Privacy predicates perform read-only comparisons on the worker. An early
    /// match is returned only after the remaining chunks and evidence authenticate.
    func inspectContent(_ handle: PantryArchiveHandle, item: @Sendable (PantryArchiveCodec.Item) throws -> Void,
                        evidence: @Sendable (Evidence) throws -> Void) throws {
        var rejection: Error?
        try readContent(handle) { _, part in
            guard rejection == nil else { return }
            do {
                switch part {
                case .items(let values): try values.forEach(item)
                case .evidence(let values): try values.forEach(evidence)
                }
            } catch { rejection = error }
        }
        try Task.checkCancellation()
        if let rejection { throw rejection }
    }

    /// Random-access callers get at most four MiB and 200 values. The entire
    /// file chain is authenticated before returning this page.
    func contentPage(_ handle: PantryArchiveHandle, after: ContentCursor? = nil, limit: Int = 200) throws -> ContentPage {
        let cursor = after ?? .init(part: 0, item: 0)
        guard (1...200).contains(limit), cursor.part >= 0, cursor.item >= 0 else { throw Failure.invalid }
        var values: [Content] = [], bytesUsed = 0, next: ContentCursor?
        let total = try readContent(handle) { part, contents in
            guard part >= cursor.part, next == nil else { return }
            let start = part == cursor.part ? cursor.item : 0
            guard start <= contents.count else { throw Failure.invalid }
            for index in start..<contents.count {
                let (value, size) = try contents.encoded(at: index)
                guard size <= PantryArchiveCodec.maximumChunkBytes else { throw Failure.invalid }
                if values.count == limit || bytesUsed + size > PantryArchiveCodec.maximumChunkBytes {
                    next = .init(part: part, item: index)
                    break
                }
                values.append(value)
                bytesUsed += size
            }
        }
        guard cursor.part < total || (cursor.part == total && cursor.item == 0) else { throw Failure.invalid }
        return .init(values: values, next: next)
    }
}
