import AVFoundation
import CryptoKit
import Darwin
import SwiftUI

// Standalone, single-attempt falsification probe. No player, engine, capture, network or app data.
@main struct CookRenderDiagnostic: App {
    var body: some Scene { WindowGroup { RenderScreen() } }
}

@MainActor private final class RenderModel: ObservableObject {
    @Published var status = "ready"
    @Published var metadata = "{}"
    private var attempt: RenderAttempt?

    func start() {
        guard attempt == nil else { return }
        status = "rendering"
        let attempt = RenderAttempt { [weak self] status, json in
            Task { @MainActor in self?.metadata = json; self?.status = status }
        }
        self.attempt = attempt
        attempt.start()
    }
}

private struct RenderScreen: View {
    @StateObject private var model = RenderModel()
    var body: some View {
        VStack(spacing: 16) {
            Text("Offline speech render diagnostic")
            Button("Render once") { model.start() }
                .disabled(model.status != "ready").accessibilityIdentifier("render.start")
            Text(model.status).accessibilityIdentifier("render.status")
            // Only scalar metadata is exposed to XCTest. The fixture/audio is never displayed.
            Text("Metadata").accessibilityIdentifier("render.metadata")
                .accessibilityLabel(model.metadata)
        }.padding()
    }
}

private enum Fixture {
    static let text = "Tuesday · Revision 3\nUse four wraps. Save two wraps for lunch."
    static let sha256 = "2704786f1a091e0ff325e09861304582ef3849ead4c47809e93629628a90c1ef"
}

private enum Limit {
    static let copies = 2
    static let copyBytes = 1_048_576
    static let fileBytes = 33_554_432
    static let pcmBytes = fileBytes - 65_536 // Leave container overhead; actual file size is also checked.
    static let events = 512
    static let jsonBytes = 262_144
    static let deadline = 30.0
    static let quietObservation = 0.25 // Observation window, NOT a documented EOF guarantee.
}

private func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }
private func context() -> [String: Any] {
    var id: UInt64 = 0
    pthread_threadid_np(nil, &id)
    return ["threadID": id, "mainThread": Thread.isMainThread,
            "reportedQoSClass": qos_class_self().rawValue]
}
private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct PCMFormat: Equatable {
    let rate: Double
    let channels: UInt32
    let common: UInt
    let interleaved: Bool
    let bytesPerFrame: UInt32
    let buffers: Int
    init(_ pcm: AVAudioPCMBuffer) {
        let f = pcm.format
        rate = f.sampleRate; channels = f.channelCount; common = f.commonFormat.rawValue
        interleaved = f.isInterleaved; bytesPerFrame = f.streamDescription.pointee.mBytesPerFrame
        buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).count
    }
    var facts: [String: Any] {
        ["sampleRate": rate, "channels": channels, "commonFormat": common,
         "interleaved": interleaved, "bytesPerFrame": bytesPerFrame, "buffers": buffers]
    }
    var valid: Bool {
        rate.isFinite && rate > 0 && channels > 0 && channels <= 8 &&
        bytesPerFrame > 0 && buffers > 0 && buffers <= 8 && common != 0
    }
}

private struct WriteOutcome {
    let index: Int
    let frames: UInt64
    let bytes: Int
    let fileSize: Int64 // -1 records a failed write without any private error text.
}

private struct Packet {
    let index: Int
    let pcm: AVAudioPCMBuffer // Owned copy, never a retained framework callback buffer.
    let format: PCMFormat
    let bytes: Int
}

// Every field is lock-protected. No native call, PCM allocation/copy, I/O or main-queue wait under lock.
private final class Mailbox: @unchecked Sendable {
    let generation = UUID().uuidString
    let began = monotonic()
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var failure: String?
    private var published = false
    private var accepting = true
    private var nextCallback = 0
    private var nextWrite = 0
    private var packets: [Int: Packet] = [:]
    private var emptyIndices: Set<Int> = []
    private var reservedCopies = 0
    private var reservedBytes = 0
    private var peakCopies = 0
    private var peakBytes = 0
    private var callbackFrames: UInt64 = 0
    private var callbackBytes: UInt64 = 0
    private var writtenFrames: UInt64 = 0
    private var writtenBytes: UInt64 = 0
    private var zeroBuffers = 0
    private var finished = false
    private var cancelled = false
    private var terminalCount = 0
    private var lastActivity = monotonic()
    private var lateCallbacks = 0
    private var format: PCMFormat?
    private var filePeakBytes: Int64 = 0
    private var fileRemoved: Bool?
    private var nativeReleased = false
    private var stopResult: Bool?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
    private func append(_ kind: String, _ fields: [String: Any] = [:]) {
        guard events.count < Limit.events else { failure = failure ?? "metadata-event-limit"; return }
        var event = fields
        event["event"] = kind; event["elapsed"] = monotonic() - began
        events.append(event)
    }
    func note(_ kind: String, _ fields: [String: Any] = [:]) {
        locked { append(kind, fields) }
    }
    func fail(_ reason: String) {
        locked { failure = failure ?? reason; append("failure", ["code": reason]) }
    }
    var error: String? { locked { failure } }
    var isReported: Bool { locked { published } }
    var matchedTerminalObserved: Bool { locked { terminalCount == 1 && (finished || cancelled) } }

    // Called on the unspecified framework callback thread. Reserve before copying; never wait for space.
    func receive(_ audio: AVAudioBuffer) {
        let callbackContext = context()
        guard let pcm = audio as? AVAudioPCMBuffer else { fail("non-pcm-buffer"); return }
        let f = PCMFormat(pcm)
        guard f.valid else { fail("unsupported-pcm-format"); return }
        let perBuffer = Int(pcm.frameLength).multipliedReportingOverflow(by: Int(f.bytesPerFrame))
        guard !perBuffer.overflow else { fail("frame-byte-overflow"); return }
        let total = perBuffer.partialValue.multipliedReportingOverflow(by: f.buffers)
        guard !total.overflow, total.partialValue <= Limit.copyBytes else { fail("single-buffer-limit"); return }
        let bytes = total.partialValue
        let index: Int? = locked {
            lastActivity = monotonic()
            guard accepting, failure == nil else {
                lateCallbacks += 1
                if !accepting { append("callback-after-seal", callbackContext) }
                return nil
            }
            if let format, format != f { failure = "format-changed"; return nil }
            format = f
            let index = nextCallback; nextCallback += 1
            var facts = callbackContext
            facts["index"] = index; facts["frames"] = pcm.frameLength; facts["bytes"] = bytes
            append("buffer", facts)
            if pcm.frameLength == 0 {
                zeroBuffers += 1; emptyIndices.insert(index); return nil
            }
            guard reservedCopies < Limit.copies, reservedBytes + bytes <= Limit.copyBytes,
                  callbackBytes + UInt64(bytes) <= UInt64(Limit.pcmBytes) else {
                failure = "callback-resource-limit"; return nil
            }
            reservedCopies += 1; reservedBytes += bytes
            peakCopies = max(peakCopies, reservedCopies); peakBytes = max(peakBytes, reservedBytes)
            callbackFrames += UInt64(pcm.frameLength); callbackBytes += UInt64(bytes)
            return index
        }
        guard let index else { return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else {
            abandon(bytes, "copy-allocation-failed"); return
        }
        copy.frameLength = pcm.frameLength
        let source = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { abandon(bytes, "copy-layout-mismatch"); return }
        for i in 0..<source.count {
            guard Int(source[i].mDataByteSize) >= perBuffer.partialValue,
                  Int(destination[i].mDataByteSize) >= perBuffer.partialValue,
                  let from = source[i].mData, let to = destination[i].mData else {
                abandon(bytes, "invalid-pcm-storage"); return
            }
            memcpy(to, from, perBuffer.partialValue)
        }
        locked {
            if accepting && failure == nil {
                packets[index] = Packet(index: index, pcm: copy, format: f, bytes: bytes)
            } else {
                reservedCopies -= 1; reservedBytes -= bytes
                append("copy-retired-after-invalidation", ["index": index])
            }
        }
    }
    private func abandon(_ bytes: Int, _ code: String) {
        locked { reservedCopies -= 1; reservedBytes -= bytes; failure = failure ?? code }
    }
    func take() -> Packet? {
        locked {
            while emptyIndices.remove(nextWrite) != nil { nextWrite += 1 }
            guard let packet = packets.removeValue(forKey: nextWrite) else { return nil }
            nextWrite += 1; return packet
        }
    }
    func wrote(_ outcome: WriteOutcome) {
        locked {
            // The packet's scope/autoreleasepool has ended before its reservation is returned.
            reservedCopies -= 1; reservedBytes -= outcome.bytes
            if outcome.fileSize < 0 { failure = failure ?? "file-write-failed"; return }
            writtenFrames += outcome.frames; writtenBytes += UInt64(outcome.bytes)
            filePeakBytes = max(filePeakBytes, outcome.fileSize)
            append("write", ["index": outcome.index, "frames": outcome.frames,
                             "bytes": outcome.bytes, "fileBytes": outcome.fileSize])
            if outcome.fileSize > Int64(Limit.fileBytes) { failure = failure ?? "file-byte-limit" }
        }
    }
    func discardQueuedCopies() {
        locked {
            for packet in packets.values { reservedCopies -= 1; reservedBytes -= packet.bytes }
            packets.removeAll(); emptyIndices.removeAll()
        }
    }
    func terminal(_ kind: String, matching: Bool) {
        let callbackContext = context()
        locked {
            lastActivity = monotonic()
            append("terminal", callbackContext.merging(["kind": kind, "matching": matching]) { _, b in b })
            guard matching else { failure = failure ?? "mismatched-terminal"; return }
            terminalCount += 1
            if kind == "finish" { finished = true } else { cancelled = true; failure = failure ?? "render-cancelled" }
            if terminalCount != 1 { failure = failure ?? "multiple-terminals" }
        }
    }
    var observedEnd: Bool {
        locked {
            failure == nil && finished && !cancelled && zeroBuffers > 0 && writtenFrames > 0 &&
            callbackFrames == writtenFrames && callbackBytes == writtenBytes && reservedCopies == 0 &&
            packets.isEmpty && monotonic() - lastActivity >= Limit.quietObservation
        }
    }
    func seal() { locked { accepting = false } }
    func closedFile(_ bytes: Int64) {
        locked {
            filePeakBytes = max(filePeakBytes, bytes)
            append("file-closed", ["bytes": bytes])
            if bytes < 0 || bytes > Int64(Limit.fileBytes) { failure = failure ?? "closed-file-size-invalid" }
        }
    }
    func stopped(_ result: Bool) { locked { stopResult = result; append("stop-return", ["result": result]) } }
    func cleaned(_ removed: Bool) { locked { fileRemoved = removed; append("file-cleanup", ["removed": removed]) } }
    func released() { locked { nativeReleased = true; append("native-references-released") } }

    // Watchdog and owner race here. First report wins; an unretired timeout can never become a pass.
    func report(_ status: String) -> String? {
        locked {
            guard !published else { return nil }; published = true
            var facts: [String: Any] = [
                "schema": 1, "status": status, "generation": generation,
                "fixtureSHA256": Fixture.sha256, "locale": "en-US", "defaultRate": true,
                "requestedOwnerQoS": "default", "defaultQoSClass": QOS_CLASS_DEFAULT.rawValue,
                "qosClassDoesNotExposeOverrides": true,
                "playerOrEngineCreated": false, "audioSessionExplicitlyActivated": false,
                "completionIsObservationOnly": true, "quietObservationSeconds": Limit.quietObservation,
                "elapsed": monotonic() - began, "callbackCount": nextCallback,
                "callbackFrames": callbackFrames, "callbackBytes": callbackBytes,
                "writtenFrames": writtenFrames, "writtenBytes": writtenBytes,
                "zeroBuffers": zeroBuffers, "matchingFinishObserved": finished,
                "matchingCancelObserved": cancelled, "terminalCount": terminalCount,
                "lateCallbacksBeforeReport": lateCallbacks, "pendingCopiesAtReport": reservedCopies,
                "peakCopies": peakCopies, "peakCopyBytes": peakBytes, "peakFileBytes": filePeakBytes,
                "nativeReferencesReleased": nativeReleased, "events": events]
            facts["error"] = failure.map { $0 as Any } ?? NSNull()
            facts["fileRemoved"] = fileRemoved.map { $0 as Any } ?? NSNull()
            facts["nativeStopResult"] = stopResult.map { $0 as Any } ?? NSNull()
            facts["format"] = format?.facts ?? [:]
            guard let data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]),
                  data.count <= Limit.jsonBytes, let json = String(data: data, encoding: .utf8) else {
                return "{\"schema\":1,\"status\":\"metadata-serialization-failed\",\"completionIsObservationOnly\":true}"
            }
            return json
        }
    }
}

private final class RenderDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let box: Mailbox
    let utteranceID: ObjectIdentifier
    let synthesizerID: ObjectIdentifier
    init(_ box: Mailbox, _ utterance: AVSpeechUtterance, _ synthesizer: AVSpeechSynthesizer) {
        self.box = box; utteranceID = ObjectIdentifier(utterance); synthesizerID = ObjectIdentifier(synthesizer)
    }
    private func matches(_ synthesizer: AVSpeechSynthesizer, _ utterance: AVSpeechUtterance) -> Bool {
        ObjectIdentifier(utterance) == utteranceID && ObjectIdentifier(synthesizer) == synthesizerID
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        box.terminal("finish", matching: matches(synthesizer, utterance))
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        box.terminal("cancel", matching: matches(synthesizer, utterance))
    }
}

// Created, used and released only by the dedicated Default-QoS thread.
private final class RenderCore {
    // Exactly one launch/attempt. A failed attempt without a matched terminal is retained until
    // process exit, never replaced by another renderer or mislabeled as successful retirement.
    private static var unretired: RenderCore?
    let box: Mailbox
    private var synth: AVSpeechSynthesizer?
    private var utterance: AVSpeechUtterance?
    private var delegate: RenderDelegate?
    private var file: AVAudioFile?
    private var directory: URL?
    private var url: URL?
    private var wroteRequest = false
    init(_ box: Mailbox) { self.box = box }

    func run() -> String {
        precondition(!Thread.isMainThread)
        box.note("owner-start", context())
        guard digest(Fixture.text) == Fixture.sha256 else { box.fail("fixture-hash-mismatch"); return "failed" }
        let catalogStart = monotonic()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        box.note("voice-catalog-return", ["seconds": monotonic() - catalogStart])
        guard let voice = voices.first(where: { $0.language == "en-US" }) else {
            box.fail("installed-en-US-unavailable"); return "failed"
        }
        box.note("voice-selected", ["language": voice.language, "identifierSHA256": digest(voice.identifier)])
        guard box.error == nil, monotonic() - box.began < Limit.deadline else { return "failed" }
        let synth = AVSpeechSynthesizer(); self.synth = synth
        synth.usesApplicationAudioSession = true // No session API or activation is requested by this probe.
        let utterance = AVSpeechUtterance(string: Fixture.text); self.utterance = utterance
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let delegate = RenderDelegate(box, utterance, synth); self.delegate = delegate; synth.delegate = delegate
        guard box.error == nil, monotonic() - box.began < Limit.deadline else { return "failed" }
        let writeStart = monotonic(); wroteRequest = true
        box.note("write-call", context())
        synth.write(utterance) { [box] buffer in box.receive(buffer) }
        box.note("write-return", ["seconds": monotonic() - writeStart])
        while box.error == nil && monotonic() - box.began < Limit.deadline {
            while let outcome = consumeNext() {
                box.wrote(outcome)
                if box.error != nil { break }
            }
            if box.observedEnd { box.seal(); return "observed-end" }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.005, false)
        }
        if box.error == nil { box.fail("owner-deadline") }
        box.seal()
        if wroteRequest {
            box.note("stop-call", context())
            let start = monotonic()
            let result = synth.stopSpeaking(at: .immediate)
            box.stopped(result)
            box.note("stop-duration", ["seconds": monotonic() - start])
            // Failure remains failure regardless of this return; no new generation is admitted.
        }
        return "failed"
    }
    private func consumeNext() -> WriteOutcome? {
        autoreleasepool {
            guard let packet = box.take() else { return nil }
            let size: Int64
            do { size = try write(packet) }
            catch { size = -1 } // No localized description, URL, fixture or audio is logged.
            return WriteOutcome(index: packet.index, frames: UInt64(packet.pcm.frameLength),
                                bytes: packet.bytes, fileSize: size)
        }
    }
    private func write(_ packet: Packet) throws -> Int64 {
        if file == nil {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CookRender-" + box.generation)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            directory = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var privateFolder = folder; try privateFolder.setResourceValues(values)
            let path = folder.appendingPathComponent("render.caf"); url = path
            file = try AVAudioFile(forWriting: path, settings: packet.pcm.format.settings,
                                   commonFormat: packet.pcm.format.commonFormat,
                                   interleaved: packet.pcm.format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete],
                                                  ofItemAtPath: path.path)
            box.note("output-format", packet.format.facts)
        }
        guard let file, let url else { throw CocoaError(.fileWriteUnknown) }
        try file.write(from: packet.pcm)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0 else { throw CocoaError(.fileReadUnknown) }
        return size
    }
    func cleanup() {
        box.seal()
        box.discardQueuedCopies()
        file = nil // Close the private CAF before deletion. No audio is exported.
        if let url {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            box.closedFile((attributes?[.size] as? NSNumber)?.int64Value ?? -1)
        }
        var removed = true
        if let directory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { removed = false; box.fail("private-file-cleanup-failed") }
            removed = removed && !FileManager.default.fileExists(atPath: directory.path)
        }
        box.cleaned(removed)
        if wroteRequest && !box.matchedTerminalObserved {
            Self.unretired = self
            box.note("retirement-unproven-native-retained-until-process-exit")
            return
        }
        synth?.delegate = nil
        delegate = nil; utterance = nil; synth = nil
        box.released()
    }
}

private final class RenderAttempt: @unchecked Sendable {
    private let box = Mailbox()
    private let publish: @Sendable (String, String) -> Void
    private var owner: Thread?
    private let watchdog = DispatchQueue(label: "org.roominthecart.diagnostics.cookrender.watchdog", qos: .default)
    init(publish: @escaping @Sendable (String, String) -> Void) { self.publish = publish }
    func start() {
        let box = box, publish = publish
        watchdog.asyncAfter(deadline: .now() + Limit.deadline) {
            guard !box.isReported else { return }
            box.fail("watchdog-deadline")
            if let json = box.report("watchdog-owner-not-retired") { publish("watchdog-owner-not-retired", json) }
        }
        let thread = Thread {
            var keeperContext = CFRunLoopSourceContext(version: 0, info: nil, retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in })
            guard let keeper = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &keeperContext) else {
                box.fail("runloop-source-failed")
                if let json = box.report("failed") { publish("failed", json) }; return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, keeper, CFRunLoopMode.defaultMode)
            autoreleasepool {
                let core = RenderCore(box)
                let status = core.run()
                core.cleanup()
                let finalStatus = box.error == nil ? status : "failed"
                if let json = box.report(finalStatus) { publish(finalStatus, json) }
            }
            CFRunLoopRemoveSource(loop, keeper, CFRunLoopMode.defaultMode)
        }
        thread.name = "CookRenderDefaultOwner"; thread.qualityOfService = .default
        owner = thread; thread.start()
    }
}
