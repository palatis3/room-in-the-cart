import Foundation
import Darwin
import RecordArchive
import CoreDomain

/// Protected external payload storage. RecoveryRegistry retains only Reference;
/// its small manifest must never embed these chunks. No file here activates a store.
@MainActor final class PantryArchiveStorage {
    enum Failure: Error, Equatable { case invalidLocation, invalidPackage, occupied, missing, tooLarge, io }
    struct Reference: Codable, Equatable, Sendable {
        let bundleID: UUID
        let manifestDigest: Data
    }
    struct FilePart: Equatable {
        let name: String
        let url: URL
        let byteCount: Int
        let digest: Data
    }
    struct VerifiedBundle {
        let reference: Reference
        let captured: PantryArchiveCapture.Captured
        /// Directory-style multipart document: manifest.json, pantry-*.json, scope-*.json.
        /// Each file is independently bounded; all are required for import readiness.
        let files: [FilePart]
    }
    struct Header: Codable {
        let namespace: String
        let version: Int
        let archive: PantryArchiveCodec.Manifest
        let scope: PantryArchiveCapture.Scope
        let evidencePageCount: Int
        let evidenceItemCount: Int
        let evidenceChainDigest: Data
    }
    struct EvidencePage: Codable {
        let version: Int
        let bundleID: UUID
        let index: Int
        let items: [PantryArchiveCapture.Evidence]
    }
    static let maximumManifestBytes = 16_384
    private static let namespace = "pantry-owner-files/v1"
    private static let manifestName = "manifest.json"
    private let root: URL
    private let limits: PantryArchiveCapture.Limits

    init(root: URL, limits: PantryArchiveCapture.Limits = .standard) throws {
        guard root.isFileURL, limits.materializedBytes > 0 else { throw Failure.invalidLocation }
        self.root = root.standardizedFileURL; self.limits = limits
        try Self.directory(self.root, create: true)
    }

    func publish(_ captured: PantryArchiveCapture.Captured, bundleID: UUID = UUID()) throws -> VerifiedBundle {
        try PantryArchiveCodec.validate(captured.snapshot); try PantryArchiveCapture.validate(captured)
        let staging = try stage()
        defer { try? FileManager.default.removeItem(at: staging) }
        var index = 0, itemCount = 0, pending: [PantryArchiveCodec.Item] = [], size = 0
        var archiveChain = Self.archiveStart, evidenceChain = Self.evidenceStart
        var totalBytes = 0
        func account(_ amount: Int) throws {
            let next = totalBytes.addingReportingOverflow(amount)
            guard !next.overflow, next.partialValue <= limits.materializedBytes else { throw Failure.tooLarge }
            totalBytes = next.partialValue
        }
        func flush() throws {
            guard !pending.isEmpty else { return }
            let chunk = PantryArchiveCodec.Chunk(namespace: PantryArchiveCodec.namespace, version: 1, bundleID: bundleID,
                descriptor: captured.snapshot.descriptor, index: index, items: pending)
            let bytes = try PantryArchiveCodec.encodeChunk(chunk)
            try account(bytes.count); try Self.write(bytes, to: staging.appendingPathComponent(Self.chunkName(index)))
            archiveChain = Self.next(archiveChain, bytes); itemCount += pending.count; index += 1; pending = []; size = 0
        }
        func append(_ item: PantryArchiveCodec.Item) throws {
            let amount = try ArchiveCodec.canonical(item).count
            guard amount <= PantryArchiveCodec.maximumChunkBytes - 2_048 else { throw Failure.tooLarge }
            if pending.count == PantryArchiveCodec.maximumChunkItems || size + amount + 2_048 > PantryArchiveCodec.maximumChunkBytes { try flush() }
            pending.append(item); size += amount + 1
        }
        let value = captured.snapshot
        for item in value.lots.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { try append(.lot(item)) }
        for item in value.observations.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { try append(.observation(item)) }
        for item in value.events.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { try append(.event(item)) }
        for item in value.reservations.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { try append(.reservation(item)) }
        for item in value.sourceLinks.sorted(by: { $0.lotID.uuidString < $1.lotID.uuidString }) { try append(.sourceLink(item)) }
        for item in value.history { try append(.historical(item)) }
        try flush()
        let manifest = PantryArchiveCodec.Manifest(namespace: PantryArchiveCodec.namespace, version: 1, bundleID: bundleID,
            descriptor: value.descriptor, chunkCount: index, itemCount: itemCount, chainDigest: archiveChain)
        var evidenceIndex = 0
        for start in stride(from: 0, to: captured.evidence.count, by: PantryArchiveCodec.maximumChunkItems) {
            let page = EvidencePage(version: 1, bundleID: bundleID, index: evidenceIndex,
                items: Array(captured.evidence[start..<min(start + PantryArchiveCodec.maximumChunkItems, captured.evidence.count)]))
            let bytes = try ArchiveCodec.canonical(page)
            guard bytes.count <= PantryArchiveCodec.maximumChunkBytes else { throw Failure.tooLarge }
            try account(bytes.count); try Self.write(bytes, to: staging.appendingPathComponent(Self.scopeName(evidenceIndex)))
            evidenceChain = Self.next(evidenceChain, bytes); evidenceIndex += 1
        }
        let header = Header(namespace: Self.namespace, version: 1, archive: manifest, scope: captured.scope,
            evidencePageCount: evidenceIndex, evidenceItemCount: captured.evidence.count, evidenceChainDigest: evidenceChain)
        let bytes = try ArchiveCodec.canonical(header)
        guard bytes.count <= Self.maximumManifestBytes else { throw Failure.tooLarge }
        try Self.write(bytes, to: staging.appendingPathComponent(Self.manifestName))
        let reference = Reference(bundleID: bundleID, manifestDigest: PantryArchiveCapture.digest(bytes))
        _ = try verify(staging, expected: reference)
        try commit(staging, id: bundleID)
        return try open(reference)
    }

    func open(_ reference: Reference) throws -> VerifiedBundle {
        guard reference.manifestDigest.count == 32 else { throw Failure.invalidPackage }
        return try verify(root.appendingPathComponent(reference.bundleID.uuidString, isDirectory: true), expected: reference)
    }

    /// The document reader supplies exact names, with a required per-file read bound.
    /// No closure or external URL is persisted. Unknown files must be rejected by the caller.
    func importFiles(manifest: Data, names: Set<String>, read: (String, Int) throws -> Data) throws -> VerifiedBundle {
        let header = try Self.header(manifest)
        try Self.validateNames(names, header: header)
        let expectedNames = names
        let reference = Reference(bundleID: header.archive.bundleID, manifestDigest: PantryArchiveCapture.digest(manifest))
        let staging = try stage()
        defer { try? FileManager.default.removeItem(at: staging) }
        var total = manifest.count
        try Self.write(manifest, to: staging.appendingPathComponent(Self.manifestName))
        for name in expectedNames.sorted() where name != Self.manifestName {
            let bytes = try read(name, PantryArchiveCodec.maximumChunkBytes)
            let sum = total.addingReportingOverflow(bytes.count)
            guard bytes.count <= PantryArchiveCodec.maximumChunkBytes, !sum.overflow,
                  sum.partialValue <= limits.materializedBytes else { throw Failure.tooLarge }
            total = sum.partialValue
            try Self.write(bytes, to: staging.appendingPathComponent(name))
        }
        _ = try verify(staging, expected: reference)
        if Self.exists(root.appendingPathComponent(reference.bundleID.uuidString)) { return try open(reference) }
        try commit(staging, id: reference.bundleID)
        return try open(reference)
    }

    /// Rechecks the current bytes before a FileDocument embeds or shares a part.
    func read(_ part: FilePart, from bundle: VerifiedBundle) throws -> Data {
        let directory = root.appendingPathComponent(bundle.reference.bundleID.uuidString, isDirectory: true)
        guard bundle.files.contains(part), part.url == directory.appendingPathComponent(part.name) else { throw Failure.invalidPackage }
        let bytes = try Self.read(part.url, maximum: part.name == Self.manifestName ? Self.maximumManifestBytes : PantryArchiveCodec.maximumChunkBytes)
        guard bytes.count == part.byteCount, PantryArchiveCapture.digest(bytes) == part.digest else { throw Failure.invalidPackage }
        return bytes
    }

    private func verify(_ directory: URL, expected: Reference) throws -> VerifiedBundle {
        try Self.directory(directory, create: false)
        let bytes = try Self.read(directory.appendingPathComponent(Self.manifestName), maximum: Self.maximumManifestBytes)
        guard PantryArchiveCapture.digest(bytes) == expected.manifestDigest else { throw Failure.invalidPackage }
        let header = try Self.header(bytes), manifest = header.archive
        guard manifest.bundleID == expected.bundleID else { throw Failure.invalidPackage }
        try Self.validateNames(Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), header: header)
        var files = [FilePart(name: Self.manifestName, url: directory.appendingPathComponent(Self.manifestName),
            byteCount: bytes.count, digest: PantryArchiveCapture.digest(bytes))]
        var total = bytes.count, itemCount = 0, chain = Self.archiveStart
        var lots: [CoreDomain.InventoryLot] = [], observations: [CoreDomain.InventoryObservation] = [], events: [CoreDomain.InventoryEvent] = []
        var claims: [CoreDomain.InventoryReservation] = [], links: [PantryPersistenceCodec.SourceLink] = [], history: [PantryArchiveCodec.History] = []
        func readPart(_ name: String) throws -> Data {
            let url = directory.appendingPathComponent(name), data = try Self.read(url, maximum: PantryArchiveCodec.maximumChunkBytes)
            let next = total.addingReportingOverflow(data.count)
            guard !next.overflow, next.partialValue <= limits.materializedBytes else { throw Failure.tooLarge }
            total = next.partialValue
            files.append(.init(name: name, url: url, byteCount: data.count, digest: PantryArchiveCapture.digest(data)))
            return data
        }
        for index in 0..<manifest.chunkCount {
            let data = try readPart(Self.chunkName(index)), chunk = try PantryArchiveCodec.decodeChunk(data)
            guard chunk.index == index, chunk.bundleID == manifest.bundleID, chunk.descriptor == manifest.descriptor else { throw Failure.invalidPackage }
            let count = itemCount.addingReportingOverflow(chunk.items.count)
            guard !count.overflow, count.partialValue <= manifest.itemCount else { throw Failure.invalidPackage }
            itemCount = count.partialValue; chain = Self.next(chain, data)
            for item in chunk.items {
                switch item {
                case .lot(let value): lots.append(value)
                case .observation(let value): observations.append(value)
                case .event(let value): events.append(value)
                case .reservation(let value): claims.append(value)
                case .sourceLink(let value): links.append(value)
                case .historical(let value): history.append(value)
                }
            }
        }
        guard itemCount == manifest.itemCount, chain == manifest.chainDigest else { throw Failure.invalidPackage }
        var evidence: [PantryArchiveCapture.Evidence] = [], evidenceChain = Self.evidenceStart
        for index in 0..<header.evidencePageCount {
            let data = try readPart(Self.scopeName(index))
            try ArchiveCodec.preflight(data, maximum: PantryArchiveCodec.maximumChunkBytes)
            let page = try JSONDecoder().decode(EvidencePage.self, from: data)
            guard page.version == 1, page.bundleID == manifest.bundleID, page.index == index,
                  !page.items.isEmpty, page.items.count <= PantryArchiveCodec.maximumChunkItems,
                  try ArchiveCodec.canonical(page) == data else { throw Failure.invalidPackage }
            evidence += page.items; evidenceChain = Self.next(evidenceChain, data)
            guard evidence.count <= header.evidenceItemCount else { throw Failure.invalidPackage }
        }
        guard evidence.count == header.evidenceItemCount, evidenceChain == header.evidenceChainDigest else { throw Failure.invalidPackage }
        let snapshot = PantryArchiveCodec.Snapshot(descriptor: manifest.descriptor, lots: lots, observations: observations,
            events: events, reservations: claims, sourceLinks: links, history: history)
        try PantryArchiveCodec.validate(snapshot)
        let captured = PantryArchiveCapture.Captured(snapshot: snapshot, scope: header.scope, evidence: evidence)
        try PantryArchiveCapture.validate(captured)
        return VerifiedBundle(reference: expected, captured: captured, files: files)
    }
    private static func header(_ data: Data) throws -> Header {
        try ArchiveCodec.preflight(data, maximum: maximumManifestBytes)
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.namespace == namespace, header.version == 1, header.evidencePageCount >= 0,
              header.evidenceItemCount >= 0, header.evidenceChainDigest.count == 32,
              (header.evidencePageCount == 0) == (header.evidenceItemCount == 0),
              header.evidencePageCount <= header.evidenceItemCount,
              try ArchiveCodec.canonical(header) == data else { throw Failure.invalidPackage }
        _ = try PantryArchiveCodec.decodeManifest(ArchiveCodec.canonical(header.archive))
        guard header.archive.chunkCount <= header.archive.itemCount else { throw Failure.invalidPackage }
        return header
    }
    private static func validateNames(_ names: Set<String>, header: Header) throws {
        let sum = header.archive.chunkCount.addingReportingOverflow(header.evidencePageCount)
        guard !sum.overflow, sum.partialValue < Int.max, names.count == sum.partialValue + 1,
              names.contains(manifestName) else { throw Failure.invalidPackage }
        // Validate the actual file set without allocating names from hostile declared counts.
        for name in names where name != manifestName {
            if name.hasPrefix("pantry-"), name.hasSuffix(".json"),
               let index = Int(name.dropFirst(7).dropLast(5)), index >= 0,
               index < header.archive.chunkCount, name == chunkName(index) { continue }
            if name.hasPrefix("scope-"), name.hasSuffix(".json"),
               let index = Int(name.dropFirst(6).dropLast(5)), index >= 0,
               index < header.evidencePageCount, name == scopeName(index) { continue }
            throw Failure.invalidPackage
        }
    }
    private func stage() throws -> URL {
        try Self.directory(root, create: false)
        let url = root.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try Self.directory(url, create: true); return url
    }
    private func commit(_ stage: URL, id: UUID) throws {
        let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !Self.exists(destination) else { throw Failure.occupied }
        try FileManager.default.moveItem(at: stage, to: destination)
    }
    private static func chunkName(_ index: Int) -> String { "pantry-\(index).json" }
    private static func scopeName(_ index: Int) -> String { "scope-\(index).json" }
    private static var archiveStart: Data { PantryArchiveCapture.digest(Data("pantry-owner-archive-chain/v1".utf8)) }
    private static var evidenceStart: Data { PantryArchiveCapture.digest(Data("pantry-owner-scope-chain/v1".utf8)) }
    private static func next(_ previous: Data, _ data: Data) -> Data { PantryArchiveCapture.digest(previous + PantryArchiveCapture.digest(data)) }
    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private static func directory(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, create else { throw Failure.invalidLocation }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw Failure.io }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidLocation }
        try protect(url, permissions: 0o700)
    }
    private static func protect(_ url: URL, permissions: Int) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: permissions]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        var value = url, resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try value.setResourceValues(resource)
    }
    private static func write(_ data: Data, to url: URL) throws {
        guard !exists(url) else { throw Failure.occupied }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url, permissions: 0o600)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.missing }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw Failure.invalidPackage }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count == info.st_size, bytes.count <= maximum else { throw Failure.invalidPackage }
        return bytes
    }
}
