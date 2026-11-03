import Foundation
import CoreDomain

struct CapturedLedgerStage {
    let preview: StagedListImport
    let alreadyApplied: Bool
}
enum CaptureLedgerImport {
    static func stage(_ capture: ReviewedCapture, in shop: ShoppingLedger) throws -> CapturedLedgerStage {
        guard let lines = capture.lines, !lines.isEmpty else { throw StructuredCaptureFailure.reviewRequired }
        let source: ImportSource
        switch capture.source {
        case .typed: source = .typed
        case .paste: source = .paste
        case .speech: source = .voice
        case .photoOCR: source = .photoOCR
        }
        let candidate = try shop.stageCaptureImport(id: capture.id, originalText: capture.originalText, source: source, lines: lines)
        if let receipt = shop.importBatches.first(where: { $0.id == capture.id }) {
            guard receipt.undoneAt == nil else { throw LedgerError.alreadyUndone }
            let saved = receipt.preview
            guard saved.source == source, saved.originalText == candidate.originalText,
                  saved.lines.count == candidate.lines.count,
                  zip(saved.lines, candidate.lines).allSatisfy({ old, new in
                      old.id == new.id && old.proposedLineID == new.proposedLineID && old.originalText == new.originalText &&
                      old.name == new.name && old.quantity == new.quantity && old.exclusions == new.exclusions && old.capture == new.capture
                  }) else { throw LedgerError.invalid("importReplay") }
            return .init(preview: saved, alreadyApplied: true)
        }
        return .init(preview: candidate, alreadyApplied: false)
    }
}
