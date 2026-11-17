import Foundation
import CoreDomain
import Combine

@MainActor final class CaptureModel: ObservableObject {
    @Published var text: String { didSet { confirmed = false } }
    @Published var confirmed = false
    @Published private(set) var candidate: CaptureEvidence?
    @Published private(set) var acceptedEvidence: CaptureEvidence?
    @Published private(set) var busy = false
    @Published private(set) var listening = false
    @Published private(set) var failure: CaptureFailure?
    private(set) var closed = false
    private var delivered = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let speech: any CaptureSpeechService
    private let ocr: any CaptureOCRService
    let id: UUID
    let localeIdentifier: String

    init(initialText: String = "", localeIdentifier: String = CaptureCorrectionScope.appLanguage(), id: UUID = UUID(),
         speech: any CaptureSpeechService, ocr: any CaptureOCRService, initialEvidence: CaptureEvidence? = nil) {
        text = initialText; self.localeIdentifier = localeIdentifier; self.id = id
        self.speech = speech; self.ocr = ocr; self.acceptedEvidence = initialEvidence
    }

    var canContinue: Bool {
        !closed && !delivered && !busy && candidate == nil && confirmed &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? CaptureLimits.validate(text)) != nil
    }
    var containsExclusion: Bool { CaptureLimits.containsExclusion(text) }

    /// Paste is invoked only from the system PasteButton; there is no clipboard read at startup.
    func stagePaste(_ values: [String]) {
        guard !closed, !busy else { return }
        stage(.init(text: values.joined(separator: "\n"), source: .paste, uncertainLines: [], sourceImageData: nil, previewImageData: nil))
    }
    func stageImage(_ data: Data) {
        guard !closed, !busy else { return }
        guard data.count <= CaptureLimits.imageBytes else { failure = .inputTooLarge; return }
        generation += 1; let current = generation
        busy = true; failure = nil; candidate = nil
        task = Task { [weak self, ocr] in
            do {
                let evidence = try await ocr.recognize(data)
                guard let self, self.generation == current, !self.closed else { return }
                self.busy = false; self.stage(evidence)
            } catch {
                guard let self, self.generation == current, !self.closed else { return }
                self.busy = false; self.failure = error as? CaptureFailure ?? .recognitionFailed
            }
        }
    }
    func startSpeech() {
        guard !closed, !busy else { return }
        generation += 1; let current = generation
        busy = true; failure = nil; candidate = nil
        task = Task { [weak self, speech] in
            guard !Task.isCancelled, self?.generation == current, let locale = self?.localeIdentifier else { return }
            do {
                let stream = try await speech.begin(localeIdentifier: locale)
                guard let self, self.generation == current, !self.closed else { speech.stop(); return }
                self.listening = true
                self.timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    self.stopSpeech()
                }
                for try await update in stream {
                    guard self.generation == current, !self.closed, !Task.isCancelled else { return }
                    try CaptureLimits.validate(update.text)
                    self.candidate = .init(text: update.text, source: .speech,
                        uncertainLines: update.uncertain ? [update.text] : [], sourceImageData: nil, previewImageData: nil)
                    if update.isFinal { self.stopSpeech(); return }
                }
                if self.generation == current { self.stopSpeech() }
            } catch {
                guard let self, self.generation == current, !self.closed else { return }
                self.stopSpeech(); self.failure = error as? CaptureFailure ?? .recognitionFailed
            }
        }
    }
    func stopSpeech() {
        generation += 1
        timeout?.cancel(); timeout = nil
        speech.stop(); task?.cancel(); task = nil
        busy = false; listening = false
    }
    func photoLoadFailed(_ reason: CaptureFailure) { guard !closed else { return }; failure = reason }
    func acceptCandidate() {
        guard !closed, !busy, let candidate else { return }
        do {
            try CaptureLimits.validate(candidate.text)
            guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureFailure.noText }
            acceptedEvidence = candidate; text = candidate.text; self.candidate = nil; failure = nil
        } catch { failure = error as? CaptureFailure ?? .recognitionFailed }
    }
    func discardCandidate() { guard !busy else { return }; candidate = nil; failure = nil }
    func reviewed(lines: [CaptureImportLine]? = nil, fieldDrafts: [CaptureLineDraft]? = nil) -> ReviewedCapture? {
        guard canContinue else { return nil }
        delivered = true
        return .init(id: id, text: text, originalText: acceptedEvidence?.text ?? text,
            source: acceptedEvidence?.source ?? .typed, localeIdentifier: localeIdentifier,
            sourceImageData: acceptedEvidence?.sourceImageData, previewImageData: acceptedEvidence?.previewImageData, lines: lines, fieldDrafts: fieldDrafts)
    }
    /// Call on route/scope exit or background. Late permission and recognition callbacks cannot restore data.
    func close() {
        closed = true; stopSpeech(); candidate = nil; acceptedEvidence = nil; text = ""; failure = nil
    }
    private func stage(_ evidence: CaptureEvidence) {
        do { try CaptureLimits.validate(evidence.text); candidate = evidence; failure = nil }
        catch { failure = .inputTooLarge }
    }
}
