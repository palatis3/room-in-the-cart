import Foundation

public struct VoiceListClip: Equatable, Sendable {
    public static let sampleRate = 16_000
    public static let maximumBytes = 30 * sampleRate * 2
    public let pcm: Data
    public var duration: TimeInterval { Double(pcm.count) / Double(Self.sampleRate * 2) }

    public init(pcm: Data) throws {
        guard (3200...Self.maximumBytes).contains(pcm.count), pcm.count.isMultiple(of: 2) else { throw ClientError.invalidResponse }
        self.pcm = pcm
    }

    /// Playback uses the very same mono signed 16-bit samples selected for submission.
    public var playbackWAV: Data {
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func add<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        tag("RIFF"); add(UInt32(pcm.count + 36)); tag("WAVEfmt "); add(UInt32(16)); add(UInt16(1)); add(UInt16(1))
        add(UInt32(Self.sampleRate)); add(UInt32(Self.sampleRate * 2)); add(UInt16(2)); add(UInt16(16))
        tag("data"); add(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

public struct VoiceTranscriptionRequest: Encodable, Equatable, Sendable {
    public let version = 1
    public let requestID: UUID
    public let issuedAt: Int64
    public let consent = true
    public let language: String
    public let samples: Int
    public let pcm: Data

    public init(consentingTo clip: VoiceListClip, language: String, now: Date = Date()) throws {
        guard ["en","es"].contains(language) else { throw ClientError.invalidResponse }
        self.requestID = UUID(); self.issuedAt = Int64(now.timeIntervalSince1970 * 1000)
        self.pcm = clip.pcm; self.samples = clip.pcm.count / 2; self.language = language
    }
}

public struct VoiceTranscription: Decodable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let language: String
    public let text: String
    public func validate(for request: VoiceTranscriptionRequest) throws {
        guard version == 1, requestID == request.requestID, language == request.language,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4096, text.utf8.count <= 8192,
              text.components(separatedBy: "\n").count <= 100,
              text.unicodeScalars.allSatisfy({ $0.value == 10 || !CharacterSet.controlCharacters.contains($0) }) else {
            throw ClientError.invalidResponse
        }
    }
}

extension HouseholdService {
    public func voiceTranscriptionAvailable(scope: ReceiptAssistanceScope) async throws -> Bool {
        try verifyReceiptAssistanceScope(scope)
        let result: ReceiptAssistanceAvailability = try await perform("capture-assistance/transcription", method: "GET",
            reportingShopID: scope.shopID, maximumResponseBytes: 1024)
        guard result.version == 1 else { throw ClientError.invalidResponse }
        return result.available
    }

    public func transcribeVoiceList(_ input: VoiceTranscriptionRequest, scope: ReceiptAssistanceScope) async throws -> VoiceTranscription {
        try verifyReceiptAssistanceScope(scope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let result: VoiceTranscription = try await perform("capture-assistance/transcription", method: "POST",
            body: encoder.encode(input), reportingShopID: scope.shopID, maximumResponseBytes: 12_288)
        try result.validate(for: input)
        return result
    }
}
