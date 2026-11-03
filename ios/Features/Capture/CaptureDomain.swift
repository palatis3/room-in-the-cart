import Foundation
import CoreDomain

enum CaptureSource: String, Sendable { case typed, paste, speech, photoOCR }
enum CaptureFailure: Error, Equatable { case notConfigured, permissionDenied, onDeviceUnavailable, audioUnavailable, recognitionFailed, imageUnavailable, inputTooLarge, noText }

struct CaptureEvidence: Equatable, Sendable {
    let text: String
    let source: CaptureSource
    let uncertainLines: [String]
    let sourceImageData: Data?
    let previewImageData: Data?
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
}

struct SpeechCaptureUpdate: Sendable {
    let text: String
    let isFinal: Bool
    let uncertain: Bool
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
