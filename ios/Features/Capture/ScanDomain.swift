import Foundation

/// A local evidence address. It conveys no role, payment, arrival or meal authority.
struct CaptureTarget: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case packageReference, recipeSource, receiptEvidence }
    let workspaceID: UUID
    let containerID: UUID
    let objectID: UUID
    let revision: Int64
    let kind: Kind
    func sameObject(as other: Self) -> Bool {
        workspaceID == other.workspaceID && containerID == other.containerID && objectID == other.objectID && kind == other.kind
    }
}
enum ScanKind: String, Sendable { case packageReference, barcode, recipe, receipt }
enum ScanFailure: Error, Equatable { case unavailable, permissionDenied, invalidImage, tooLarge, invalidText, needsReview, stale, retired, replay, storage }
struct CapturedBarcode: Codable, Equatable, Identifiable, Sendable {
    var id: String { symbology + ":" + value }
    let symbology: String
    let value: String
    /// A syntactically valid GTIN is still only a code, never a product or ingredient-safety match.
    var validGTIN: Bool {
        guard [8, 12, 13, 14].contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        let digits = value.utf8.map { Int($0 - 48) }
        let body = digits.dropLast().reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        return (10 - body % 10) % 10 == digits.last
    }
    func validate() throws {
        guard !symbology.isEmpty, symbology.utf8.count <= 64, !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ScanFailure.invalidText }
    }
}
struct ScannedSource: Equatable, Sendable {
    let originalText: String
    let uncertainLines: [String]
    let originalImageData: Data
    let referenceJPEG: Data
    let barcodes: [CapturedBarcode]
}
/// Receipt rows are literal evidence only. These strings never become Money, ReceiptFragment or usable stock.
struct ScanReceiptLine: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let originalText: String
    var reviewedText: String
    var quantityNote: String
    var priceNote: String
    init(id: UUID = UUID(), originalText: String, reviewedText: String? = nil, quantityNote: String = "", priceNote: String = "") {
        self.id = id; self.originalText = originalText; self.reviewedText = reviewedText ?? originalText
        self.quantityNote = quantityNote; self.priceNote = priceNote
    }
}
struct SourceMediaReference: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let mediaID: UUID
}
struct SourceMediaRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let target: CaptureTarget
    let originalText: String
    var reviewedText: String? = nil
    let reviewedLabel: String
    let imageJPEG: Data?
    let barcode: CapturedBarcode?
    let receiptLines: [ScanReceiptLine]
    let capturedAt: Date
    var reference: SourceMediaReference { .init(workspaceID: target.workspaceID, mediaID: id) }
    func validate() throws {
        guard target.revision >= 0, capturedAt.timeIntervalSinceReferenceDate.isFinite,
              !reviewedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reviewedLabel.utf8.count <= 512, !reviewedLabel.contains("\0"),
              receiptLines.count <= 200, Set(receiptLines.map(\.id)).count == receiptLines.count else { throw ScanFailure.invalidText }
        try ScanLimits.text(originalText)
        if let reviewedText { try ScanLimits.text(reviewedText) }
        var total = 0
        for row in receiptLines {
            for text in [row.originalText, row.reviewedText, row.quantityNote, row.priceNote] {
                guard text.utf8.count <= 2048, !text.contains("\0") else { throw ScanFailure.invalidText }
                total += text.utf8.count
            }
        }
        guard total <= 80_000, target.kind == .receiptEvidence || receiptLines.isEmpty else { throw ScanFailure.tooLarge }
        try barcode?.validate()
        if let imageJPEG { try ScanImageNormalizer.validateReference(imageJPEG) }
    }
}
enum ScanLimits {
    static let maximumReferenceBytes = 1_500_000
    static let maximumRecordBytes = 2_100_000
    static let maximumWorkspaceRecords = 12
    static func text(_ value: String) throws {
        guard value.utf8.count <= 20_000, !value.contains("\0"), value.split(whereSeparator: \.isNewline).count <= 200 else { throw ScanFailure.tooLarge }
    }
    static func receiptLines(_ original: String) throws -> [ScanReceiptLine] {
        try text(original)
        return original.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { .init(originalText: $0) }
    }
}
protocol LocalScanService: Sendable { func scan(_ data: Data) async throws -> ScannedSource }
