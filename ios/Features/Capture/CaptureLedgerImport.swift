import Foundation
import CoreDomain

struct CapturedLedgerStage {
    let preview: StagedListImport
    let alreadyApplied: Bool
}
enum CaptureLedgerImport {
    static func stage(_ capture: ReviewedCapture, in workspace: LedgerWorkspace, currentShopID: UUID) throws -> CapturedLedgerStage {
        guard workspace.selectedShopID == currentShopID else { throw StructuredCaptureFailure.destinationMismatch }
        let targetID = capture.naturalBatch?.pickup?.id ?? currentShopID
        guard let shop = workspace.shops.first(where: { $0.id == targetID }),
              !workspace.shops.contains(where: { $0.id != targetID && $0.importBatches.contains { $0.id == capture.id } }) else {
            throw StructuredCaptureFailure.destinationMismatch
        }
        return try stage(capture, in: shop)
    }

    static func stage(_ capture: ReviewedCapture, in shop: ShoppingLedger) throws -> CapturedLedgerStage {
        guard let lines = capture.lines, !lines.isEmpty else { throw StructuredCaptureFailure.reviewRequired }
        if let batch = capture.naturalBatch {
            guard let pickup = batch.pickup, pickup.id == shop.id, lines.allSatisfy({ $0.destination == pickup.title }) else {
                throw StructuredCaptureFailure.destinationMismatch
            }
            if !shop.importBatches.contains(where: { $0.id == capture.id }), pickup != CapturePickup(shop) {
                throw StructuredCaptureFailure.destinationMismatch
            }
        }
        let source: ImportSource
        switch capture.source {
        case .typed: source = .typed
        case .paste: source = .paste
        case .speech: source = .voice
        case .assistedSpeech: source = .assistedVoice
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
