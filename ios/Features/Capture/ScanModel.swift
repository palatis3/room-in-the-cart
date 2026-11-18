import Foundation
import Combine
import CoreDomain

@MainActor final class ScanModel: ObservableObject {
    @Published var text: String {
        didSet {
            confirmed = false
            if !imageReadings.isEmpty {
                let lines = text.components(separatedBy: "\n")
                imageReadings = imageReadings.filter { lines.indices.contains($0.key) && lines[$0.key] == $0.value.text }
            }
        }
    }
    private var imageReadings: [Int: ReviewedImageWording] = [:]
    @Published var confirmed = false
    @Published private(set) var candidate: ScannedSource?
    @Published private(set) var accepted: ScannedSource?
    @Published private(set) var busy = false
    @Published private(set) var failure: ScanFailure?
    @Published private(set) var source: CaptureSource = .typed
    private var pastedOriginal: String?
    private var draftBeforePhoto: (text: String, source: CaptureSource, pastedOriginal: String?)?
    var originalText: String { accepted?.originalText ?? pastedOriginal ?? text }
    let id: UUID
    let capturedAt: Date
    private let service: any LocalScanService
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private(set) var closed = false
    private var delivered = false
    init(text: String = "", id: UUID = UUID(), capturedAt: Date = Date(), service: any LocalScanService = OnDeviceScanService()) {
        self.text = text; self.id = id; self.capturedAt = capturedAt; self.service = service
    }
    func stage(_ data: Data) {
        guard !closed, !busy else { return }
        guard data.count <= CaptureLimits.imageBytes else { failure = .tooLarge; return }
        busy = true; failure = nil; confirmed = false
        let current = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.scan(data)
                guard let self, !self.closed, self.generation == current else { return }
                self.candidate = result; self.busy = false
            } catch {
                guard let self, !self.closed, self.generation == current else { return }
                self.busy = false; self.failure = error as? ScanFailure ?? .unavailable
            }
        }
    }
    @discardableResult func paste(_ values: [String]) -> Bool {
        guard !closed, !busy else { return false }
        let value = values.joined(separator: "\n")
        do { try ScanLimits.text(value) } catch { failure = .tooLarge; return false }
        draftBeforePhoto = nil
        imageReadings = [:]; pastedOriginal = value; accepted = nil; candidate = nil; source = .paste; text = value
        failure = nil
        return true
    }
    func acceptCandidate() {
        guard !closed, !busy, let candidate else { return }
        if draftBeforePhoto == nil { draftBeforePhoto = (text, source, pastedOriginal) }
        imageReadings = [:]; accepted = candidate; source = .photoOCR; pastedOriginal = nil; text = candidate.originalText; self.candidate = nil; failure = nil
    }
    func applyRecipeImageReading(_ reading: ReviewedImageWording, line: Int, reviewedText: String, source: ScannedSource) throws {
        guard !closed, !delivered, !busy, accepted == source, text == reviewedText else { throw ScanFailure.stale }
        try reading.validate()
        var lines = reviewedText.components(separatedBy: "\n")
        guard lines.indices.contains(line), lines.count <= CaptureLimits.lines else { throw ScanFailure.stale }
        lines[line] = reading.text
        let updated = lines.joined(separator: "\n")
        try ScanLimits.text(updated)
        text = updated
        imageReadings[line] = reading
    }
    func discardCandidate() { guard !busy else { return }; candidate = nil }
    func inputFailed(_ value: ScanFailure) { guard !closed else { return }; failure = value }
    func reviewed(target: CaptureTarget, label: String, barcode: CapturedBarcode?, receiptLines: [ScanReceiptLine] = []) throws -> SourceMediaRecord {
        guard !closed, !delivered, !busy, candidate == nil, confirmed else { throw ScanFailure.needsReview }
        try ScanLimits.text(text)
        var record = SourceMediaRecord(id: id, target: target, originalText: originalText,
            reviewedText: text != originalText ? text : nil, reviewedLabel: label, imageJPEG: accepted?.referenceJPEG, barcode: barcode,
            receiptLines: receiptLines, capturedAt: capturedAt)
        if !imageReadings.isEmpty { record.reviewedImageLines = imageReadings }
        try record.validate()
        delivered = true
        return record
    }
    func revokePhotoConsent() {
        generation = UUID(); task?.cancel(); task = nil; busy = false
        candidate = nil; accepted = nil; imageReadings = [:]; failure = nil; confirmed = false
        if let before = draftBeforePhoto {
            text = before.text; source = before.source; pastedOriginal = before.pastedOriginal
            draftBeforePhoto = nil
        }
    }
    func close() {
        closed = true; generation = UUID(); task?.cancel(); task = nil; busy = false
        candidate = nil; accepted = nil; imageReadings = [:]; pastedOriginal = nil; draftBeforePhoto = nil; text = ""; confirmed = false
    }
}
