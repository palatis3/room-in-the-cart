@preconcurrency import AVFoundation
import Combine
import HouseholdClient

/// One input tap, one converter and a duration-limited buffer. All recording and playback bytes stay in memory.
final class VoiceListSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private var samples = Data()
    private var failed = false

    init(input: AVAudioFormat) throws {
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceListClip.sampleRate),
                channels: 1, interleaved: false), let converter = AVAudioConverter(from: input, to: output) else {
            throw CaptureFailure.audioUnavailable
        }
        self.output = output
        self.converter = converter
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !failed, samples.count < VoiceListClip.maximumBytes else { return }
        let capacity = ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard capacity.isFinite, capacity > 0, capacity < 65_536,
              let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(capacity)) else { failed = true; return }
        var offered = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if offered { state.pointee = .noDataNow; return nil }
            offered = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let channel = result.int16ChannelData?[0] else { failed = true; return }
        let bytes = min(Int(result.frameLength) * 2, VoiceListClip.maximumBytes - samples.count)
        if bytes > 0 { samples.append(contentsOf: UnsafeRawBufferPointer(start: channel, count: bytes)) }
    }
    func clip() throws -> VoiceListClip {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw CaptureFailure.audioUnavailable }
        return try VoiceListClip(pcm: samples)
    }
}

@MainActor final class VoiceListRecording: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var preparing = false
    @Published private(set) var failed = false
    @Published private(set) var clip: VoiceListClip?
    private var engine: AVAudioEngine?
    private var samples: VoiceListSampleBuffer?
    private var lease: CookCaptureAudioRequest?
    private var player: AVAudioPlayer?
    private var playbackEnd: Task<Void,Never>?
    private lazy var playback = CookSpeechSessionBinding(audio: .shared, stop: { [weak self] in self?.stopPlayback() })
    private var limit: Task<Void,Never>?
    private var generation = UUID()

    func start() async {
        clear()
        let run = generation
        preparing = true
        defer { if generation == run { preparing = false } }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard run == generation, !Task.isCancelled else { return }
        guard allowed else { failed = true; return }
        let request = CookCaptureAudioRequest(audio: .shared)
        lease = request
        let ready = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in request.acquire { continuation.resume(returning: $0) } }
        } onCancel: { request.cancel() }
        guard run == generation, !Task.isCancelled else { request.cancel(); return }
        guard ready else { request.cancel(); lease = nil; failed = true; return }
        do {
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            let samples = try VoiceListSampleBuffer(input: format)
            node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in samples.append(buffer) }
            self.engine = engine; self.samples = samples
            engine.prepare(); try engine.start()
            recording = true
            limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, self?.generation == run else { return }
                self?.stop()
            }
        } catch { releaseRecording(); failed = true }
    }

    func stop() {
        guard recording else { return }
        let captured = samples
        releaseRecording()
        do { clip = try captured?.clip(); failed = clip == nil }
        catch { failed = true }
    }

    func play() {
        guard let clip, !recording, !preparing else { return }
        stopPlayback()
        let intent = UUID()
        guard playback.begin(intent, changed: { [weak self] changed in
            guard self?.playback.currentIntent == changed else { return }
            self?.stopPlayback()
        }) else { failed = true; return }
        playback.acquire(UUID()) { [weak self] ready in
            guard let self, playback.currentIntent == intent else { return }
            guard ready, playback.admit(intent) == .ready else { stopPlayback(); failed = true; return }
            do {
                let player = try AVAudioPlayer(data: clip.playbackWAV)
                self.player = player
                guard player.play() else { throw CaptureFailure.audioUnavailable }
                playbackEnd = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(clip.duration))
                    guard !Task.isCancelled, self?.playback.currentIntent == intent else { return }
                    self?.stopPlayback()
                }
            } catch { stopPlayback(); failed = true }
        }
    }

    func stopPlayback() {
        playbackEnd?.cancel(); playbackEnd = nil; player?.stop(); player = nil
        playback.retire()
    }
    func clear() {
        generation = UUID(); releaseRecording(); stopPlayback()
        clip = nil; failed = false; preparing = false
    }
    private func releaseRecording() {
        limit?.cancel(); limit = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        self.engine = nil; samples = nil; recording = false; lease?.cancel(); lease = nil
    }
}
