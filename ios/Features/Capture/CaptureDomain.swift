import Foundation
import CoreDomain

enum CaptureSource: String, Sendable { case typed, paste, speech, assistedSpeech, photoOCR }
enum CaptureFailure: Error, Equatable { case notConfigured, permissionDenied, onDeviceUnavailable, audioUnavailable, recognitionFailed, imageUnavailable, inputTooLarge, noText }

struct CaptureEvidence: Equatable, Sendable {
    let text: String
    let source: CaptureSource
    let uncertainLines: [String]
    let sourceImageData: Data?
    let previewImageData: Data?
    var speechRepairs: [SpeechWordRepair] = []
}

/// A review result, not a saved ledger mutation or verified food/price fact.
struct ReviewedCapture: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let originalText: String
    let source: CaptureSource
    let localeIdentifier: String
    let sourceImageData: Data?
    var previewImageData: Data? = nil
    var lines: [CaptureImportLine]? = nil
    var fieldDrafts: [CaptureLineDraft]? = nil
    var naturalBatch: NaturalCaptureBatch? = nil
}

/// A pickup offered by the authorized private workspace, identified independently of its display name.
struct CapturePickup: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let revision: Int

    init(_ shop: ShoppingLedger) {
        id = shop.id
        title = shop.title
        revision = shop.revision
    }
}

extension CaptureLineDraft {
    var needsNaturalClarification: Bool {
        warnings.contains(.ambiguous) || warnings.contains(.negation) || warnings.contains(.packUnknown)
    }
}

struct NaturalCaptureBatch: Equatable, Sendable {
    let timing: String?
    var pickup: CapturePickup?

    init(timing: String?, lines: [CaptureLineDraft], currentPickup: CapturePickup?) {
        self.timing = timing
        pickup = timing == nil && !lines.contains { $0.warnings.contains(.destination) } ? currentPickup : nil
    }

    mutating func refreshPickups(_ available: [CapturePickup]) {
        if let pickup, !available.contains(pickup) { self.pickup = nil }
    }

    func reviewed(_ drafts: [CaptureLineDraft], availablePickups: [CapturePickup]) throws -> [CaptureImportLine] {
        guard let pickup, availablePickups.contains(pickup) else { throw StructuredCaptureFailure.destinationMismatch }
        let rows: [CaptureImportLine] = try drafts.compactMap { draft in
            guard draft.skip || !draft.needsNaturalClarification || draft.confirmed else {
                throw StructuredCaptureFailure.reviewRequired
            }
            var line = draft
            line.destination = pickup.title
            line.confirmed = true
            return try line.reviewed(expectedDestination: pickup.title)
        }
        guard !rows.isEmpty else { throw StructuredCaptureFailure.reviewRequired }
        return rows
    }
}

/// The offset belongs to this transcript, including when the same word occurs twice.
struct SpeechWordRepair: Equatable, Sendable, Identifiable {
    let id: Int
    var range: NSRange
    let word: String
    let alternatives: [String]

    init?(text: String, range: NSRange, word: String, alternatives: [String]) {
        guard let span = Range(range, in: text), !word.isEmpty, String(text[span]) == word else { return nil }
        var seen: Set<String> = [word]
        let choices = alternatives.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 &&
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && seen.insert($0).inserted
        }
        guard !choices.isEmpty else { return nil }
        self.id = range.location; self.range = range; self.word = word
        self.alternatives = Array(choices.prefix(2))
    }
}

struct SpeechCaptureUpdate: Sendable {
    let text: String
    let isFinal: Bool
    let uncertain: Bool
    var repairs: [SpeechWordRepair] = []
}

@MainActor protocol CaptureSpeechService {
    func begin(localeIdentifier: String) async throws -> AsyncThrowingStream<SpeechCaptureUpdate, Error>
    func stop()
}
protocol CaptureOCRService: Sendable { func recognize(_ data: Data) async throws -> CaptureEvidence }

enum CaptureLimits {
    static let textCharacters = 20_000
    static let imageBytes = 12 * 1_024 * 1_024
    static let lines = 200
    static func validate(_ text: String) throws {
        guard text.count <= textCharacters, text.split(whereSeparator: \.isNewline).count <= lines else { throw CaptureFailure.inputTooLarge }
    }
    static func containsExclusion(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["no", "not", "without", "except", "sin", "excepto", "menos"])
    }
}

struct CaptureTextPosition: Sendable {
    let midY: Double
    let minX: Double
}

/// Strict total order. Pairwise row tolerances can create comparison cycles.
enum CaptureReadingOrder {
    static func indices(_ positions: [CaptureTextPosition]) -> [Int] {
        positions.indices.sorted { left, right in
            let a = positions[left], b = positions[right]
            let ay = a.midY.isFinite ? a.midY : -Double.infinity
            let by = b.midY.isFinite ? b.midY : -Double.infinity
            if ay != by { return ay > by }
            let ax = a.minX.isFinite ? a.minX : Double.infinity
            let bx = b.minX.isFinite ? b.minX : Double.infinity
            if ax != bx { return ax < bx }
            return left < right
        }
    }
}
