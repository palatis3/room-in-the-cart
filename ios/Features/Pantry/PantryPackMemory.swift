import Combine
import CoreDomain
import Foundation
import LocalStore

struct ConfirmedPantryPack: Codable, Equatable, Identifiable {
    let id: UUID
    let barcode: CapturedBarcode
    let retailer: String
    let name: String
    let size: Quantity
    let attribution: String?
    let confirmedAt: Date
    var evidenceLotID: UUID? = nil
    var evidenceLineID: UUID? = nil
    var key: String? { barcode.associationKey(retailer: retailer) }
    var label: String { name + " · " + pantryQuantity(size) }

    func validate() throws {
        try barcode.validate()
        try size.validate()
        guard size.amount > .zero, key != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 512, !name.contains("\0"), (attribution?.utf8.count ?? 0) <= 2048 else {
            throw ProductBatchError.invalid
        }
    }
}

struct RecordedPackReceiptLink: Codable, Equatable, Identifiable {
    let id: UUID
    let receiptID: UUID
    let lineID: UUID
    let lotID: UUID
    let code: CapturedBarcode
}

@MainActor final class PantryPackMemory: ObservableObject {
    private struct Document: Codable {
        let origin: UUID
        let owner: String
        var packs: [ConfirmedPantryPack]
        var links: [RecordedPackReceiptLink]? = nil
    }
    private let root: URL
    @Published private(set) var generation = UUID()
    init(folder: URL) { root = folder }

    private func url(_ scope: PantryDigestScope) -> URL {
        root.appendingPathComponent(scope.origin.uuidString, isDirectory: true).appendingPathComponent(scope.owner + ".json")
    }
    func recent(_ scope: PantryDigestScope) throws -> [ConfirmedPantryPack] { try document(scope).packs }

    private func document(_ scope: PantryDigestScope) throws -> Document {
        let path = url(scope)
        guard FileManager.default.fileExists(atPath: path.path) else { return .init(origin: scope.origin, owner: scope.owner, packs: []) }
        let document = try read(path)
        guard document.origin == scope.origin, document.owner == scope.owner else { throw ProductBatchError.invalid }
        return document
    }
    private func read(_ path: URL) throws -> Document {
        let doc = try JSONDecoder().decode(Document.self, from: PantryArchiveFiles.read(path, maximum: 2_097_152))
        guard doc.packs.count <= 1000, Set(doc.packs.compactMap(\.key)).count == doc.packs.count else { throw ProductBatchError.invalid }
        let links = doc.links ?? []
        guard links.count <= 2000, Set(links.map(\.id)).count == links.count else { throw ProductBatchError.invalid }
        try links.forEach { try $0.code.validate() }
        try doc.packs.forEach { try $0.validate() }
        return doc
    }
    func match(_ code: CapturedBarcode, retailer: String, scope: PantryDigestScope) throws -> ConfirmedPantryPack? {
        guard let key = code.associationKey(retailer: retailer) else { return nil }
        return try recent(scope).first { $0.key == key }
    }
    func replace(_ previous: ConfirmedPantryPack?, with next: ConfirmedPantryPack?, scope: PantryDigestScope, authorized: () -> Bool) throws {
        guard authorized(), let key = (previous ?? next)?.key, next == nil || next?.key == key else { throw ProductBatchError.invalid }
        var data = try document(scope)
        var rows = data.packs
        guard rows.first(where: { $0.key == key }) == previous else { throw PantryDigestFailure.changed }
        rows.removeAll { $0.key == key }
        if let next { try next.validate(); rows.insert(next, at: 0) }
        data.packs = rows
        try write(data, to: url(scope))
    }
    func receiptLinks(lotID: UUID, scope: PantryDigestScope) throws -> [RecordedPackReceiptLink] {
        try (document(scope).links ?? []).filter { $0.lotID == lotID }
    }
    func link(_ link: RecordedPackReceiptLink, scope: PantryDigestScope, authorized: () -> Bool) throws {
        guard authorized() else { throw PantryDigestFailure.changed }
        try link.code.validate()
        var data = try document(scope)
        var links = data.links ?? []
        if let prior = links.first(where: { $0.id == link.id }) {
            guard prior == link else { throw PantryDigestFailure.changed }
            return
        }
        guard links.count < 2000 else { throw PantryDigestFailure.capacity }
        links.append(link); data.links = links
        try write(data, to: url(scope))
    }
    private func write(_ doc: Document, to url: URL) throws {
        guard doc.packs.count <= 1000 else { throw PantryDigestFailure.capacity }
        if doc.packs.isEmpty && (doc.links?.isEmpty ?? true) {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            let data = try JSONEncoder().encode(doc)
            guard data.count <= 2_097_152 else { throw PantryDigestFailure.capacity }
            try PantryArchiveFiles.directory(url.deletingLastPathComponent(), create: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try PantryArchiveFiles.protect(url, permissions: 0o600)
        }
        generation = UUID()
    }
    func erase(origin: UUID, whole: Bool, stillHasLot: (UUID) async throws -> Bool) async throws {
        let folder = root.appendingPathComponent(origin.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if whole {
            try FileManager.default.removeItem(at: folder)
            generation = UUID()
        } else {
            for path in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if path.lastPathComponent.hasPrefix("pending-") {
                    try FileManager.default.removeItem(at: path)
                    continue
                }
                let prior = try read(path)
                var removed = Set<UUID>()
                for pack in prior.packs {
                    if let lot = pack.evidenceLotID, try await !stillHasLot(lot) { removed.insert(lot) }
                }
                for lot in Set((prior.links ?? []).map(\.lotID)) {
                    if try await !stillHasLot(lot) { removed.insert(lot) }
                }
                guard !removed.isEmpty else { continue }
                var current = try read(path)
                current.packs.removeAll { $0.evidenceLotID.map(removed.contains) == true }
                current.links?.removeAll { removed.contains($0.lotID) }
                try write(current, to: path)
            }
        }
    }
}

/// The first irreversible write follows this protected, fully reviewed operation. A reopened
/// editor can resend the same SQLite operation after termination, including a lost acknowledgment.
struct ReviewedPackSave: Codable, Equatable {
    struct Row: Codable, Equatable, Identifiable {
        let id: UUID
        let lotID: UUID
        let name: String
        let description: String
    }
    let owner: String
    let batch: InventoryBatch
    let rows: [Row]
    var review: PantryReceiptReview {
        .init(id: batch.operationID, workspaceID: batch.workspaceID, revision: batch.expectedRevision, facts: [], existing: [], batch: batch)
    }
    init?(review: PantryReceiptReview, intake: PantryProductBatch, scope: PantryDigestScope, atHome: Bool) throws {
        guard let batch = review.batch else { return nil }
        guard scope.origin == intake.workspaceID, scope.origin == review.workspaceID, review.id == batch.operationID else { throw ProductBatchError.invalid }
        self.batch = batch; owner = scope.owner
        rows = try intake.candidates.filter(\.included).map { candidate in
            let lot = atHome ? candidate.id : review.facts.first { $0.ordinal == candidate.ordinal }?.lotID
            guard let lot else { throw ProductBatchError.invalid }
            return Row(id: candidate.id, lotID: lot, name: candidate.name, description: candidate.reviewEvidenceLine)
        }
        try validate(scope)
    }
    func validate(_ scope: PantryDigestScope) throws {
        guard batch.workspaceID == scope.origin, owner == scope.owner, batch.mode == .mutate, batch.expectedRevision >= 0,
              batch.erasures.isEmpty, batch.comparisons.isEmpty, batch.aliasEdit == nil, batch.price == nil,
              (1...12).contains(rows.count), Set(rows.map(\.id)).count == rows.count else { throw ProductBatchError.invalid }
    }
}

extension PantryPackMemory {
    private func pendingURL(_ scope: PantryDigestScope) -> URL {
        url(scope).deletingLastPathComponent().appendingPathComponent("pending-" + scope.owner + ".json")
    }
    func pending(_ scope: PantryDigestScope) throws -> ReviewedPackSave? {
        let url = pendingURL(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(ReviewedPackSave.self, from: PantryArchiveFiles.read(url, maximum: 2_097_152))
        try record.validate(scope)
        return record
    }
    func stage(_ record: ReviewedPackSave, scope: PantryDigestScope, authorized: () -> Bool) throws {
        guard authorized() else { throw PantryDigestFailure.changed }
        if let old = try pending(scope) {
            guard old == record else { throw PantryDigestFailure.changed }
            return
        }
        try record.validate(scope)
        let url = pendingURL(scope)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 2_097_152 else { throw PantryDigestFailure.capacity }
        try PantryArchiveFiles.directory(url.deletingLastPathComponent(), create: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try PantryArchiveFiles.protect(url, permissions: 0o600)
    }
    func clear(_ record: ReviewedPackSave, scope: PantryDigestScope, authorized: () -> Bool) throws {
        guard authorized() else { throw PantryDigestFailure.changed }
        guard let old = try pending(scope) else { return }
        guard old == record else { throw PantryDigestFailure.changed }
        try FileManager.default.removeItem(at: pendingURL(scope))
    }
}
