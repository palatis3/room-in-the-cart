import AVFoundation
import UIKit

/// Opt-in fixture diagnostics contain only fixed phases and monotonic time.
private enum CookReadbackTrace {
    enum Phase: String {
        case voicesStarted, voicesReturned, voicesDelivered, audioQueued, audioReady, audioUnavailable
        case preparationStarted, preparationReady, preparationUnavailable, stopped
        case intentReady, intentPending, intentInvalid, admissionReady, admissionPending, admissionInvalid
    }
    static func record(_ phase: Phase) {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--ui-testing"), process.arguments.contains("--shared-delivery-fixture"),
              process.environment["RITC_COOK_READBACK_TRACE"] == "1" else { return }
        print("RITC_COOK_READBACK_TRACE uptime=\(process.systemUptime) phase=\(phase.rawValue)")
        #endif
    }
    static func gate(_ gate: CookAudioGate, admission: Bool) {
        switch gate {
        case .ready: record(admission ? .admissionReady : .intentReady)
        case .pending: record(admission ? .admissionPending : .intentPending)
        case .invalid: record(admission ? .admissionInvalid : .intentInvalid)
        }
    }
}

/// Local installed voices only. Playback never requests microphone or speech-recognition permission.
@MainActor final class LocalCookSpeech: NSObject, CookSpeechPlayback, AVSpeechSynthesizerDelegate {
    var onEnd: ((UUID) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: UUID] = [:]
    private let audio: CookAudioSession
    private lazy var binding = CookSpeechSessionBinding(audio: audio, stop: { [weak self] in self?.stop() })
    private lazy var preparation = CookSpeechPreparation<AVSpeechSynthesisVoice>(
        loadVoices: CookInstalledVoices.discovery.load,
        acquire: { [weak self] lease, completion in
            guard let self else { completion(false); return }
            CookReadbackTrace.record(.audioQueued)
            self.binding.acquire(lease) { ready in
                CookReadbackTrace.record(ready ? .audioReady : .audioUnavailable)
                completion(ready)
            }
        },
        release: { [audio] in audio.release($0) }, uniqueLeaseIDs: true
    )

    init(audio: CookAudioSession = .shared) { self.audio = audio; super.init(); synthesizer.delegate = self }
    func beginIntent(_ id: UUID, changed: @escaping @MainActor @Sendable (UUID) -> Void) -> Bool {
        binding.begin(id, changed: changed)
    }
    func intentGate(_ id: UUID) -> CookAudioGate {
        let gate = binding.intentGate(id)
        CookReadbackTrace.gate(gate, admission: false)
        return gate
    }
    func admitPlayback(_ id: UUID) -> CookAudioGate {
        let gate = binding.admit(id)
        CookReadbackTrace.gate(gate, admission: true)
        return gate
    }
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard binding.currentIntent == id else { completion(false); return }
        CookReadbackTrace.record(.preparationStarted)
        preparation.prepare(for: id) { ready in
            CookReadbackTrace.record(ready ? .preparationReady : .preparationUnavailable)
            completion(ready)
        }
    }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        guard preparation.sessionID == playbackID else { throw CaptureFailure.audioUnavailable }
        guard !UIAccessibility.isVoiceOverRunning else { throw CaptureFailure.audioUnavailable }
        guard let voice = preparation.installedVoice(localeIdentifier: localeIdentifier, language: { $0.language })
        else { throw CaptureFailure.onDeviceUnavailable }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        ids[ObjectIdentifier(utterance)] = playbackID
        synthesizer.speak(utterance)
    }
    func pause() -> Bool {
        let paused = synthesizer.pauseSpeaking(at: .immediate)
        if paused { preparation.releaseAudio() }
        return paused
    }
    func resume() throws -> Bool {
        guard !UIAccessibility.isVoiceOverRunning else { throw CaptureFailure.audioUnavailable }
        return synthesizer.continueSpeaking()
    }
    func stop() {
        CookReadbackTrace.record(.stopped)
        binding.invalidate()
        if !ids.isEmpty { synthesizer.stopSpeaking(at: .immediate) }
        ids.removeAll()
        deactivate()
        binding.retire()
    }
    private func deactivate() {
        preparation.invalidate()
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let id = self.ids.removeValue(forKey: key) else { return }
            self.deactivate(); self.onEnd?(id)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let id = self.ids.removeValue(forKey: key) else { return }
            self.deactivate(); self.onEnd?(id)
        }
    }
}

/// Only installed-voice discovery crosses this queue; synthesizers and utterances stay on MainActor.
@MainActor private enum CookInstalledVoices {
    static let queue = DispatchQueue(label: "dev.roominthecart.cook-installed-voices", qos: .userInitiated)

    static let discovery = CookVoiceDiscovery<AVSpeechSynthesisVoice>(timeout: .seconds(5)) { completion in
        queue.async {
            CookReadbackTrace.record(.voicesStarted)
            let voices = AVSpeechSynthesisVoice.speechVoices()
            CookReadbackTrace.record(.voicesReturned)
            DispatchQueue.main.async {
                CookReadbackTrace.record(.voicesDelivered)
                completion(voices)
            }
        }
    }
}

/// Share only an in-flight system lookup. Each Play gets its own deadline, including a
/// retry while the system is still loading voices. A late result cannot start expired playback.
@MainActor final class CookVoiceDiscovery<Voice: Sendable> {
    typealias Completion = @MainActor @Sendable ([Voice]) -> Void
    private let timeout: Duration
    private let lookup: (@escaping Completion) -> Void
    private var loading = false
    private var pending: [UUID: (reply: Completion, timer: Task<Void, Never>)] = [:]

    init(timeout: Duration, lookup: @escaping (@escaping Completion) -> Void) {
        self.timeout = timeout
        self.lookup = lookup
    }

    func load(_ reply: @escaping Completion) {
        let id = UUID()
        let timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.pending.removeValue(forKey: id)?.reply([])
        }
        pending[id] = (reply, timer)
        guard !loading else { return }
        loading = true
        lookup { [weak self] voices in
            guard let self else { return }
            self.loading = false
            let requests = self.pending
            self.pending.removeAll()
            for request in requests.values {
                request.timer.cancel()
                request.reply(voices)
            }
        }
    }
}

/// A catalog belongs to one playback, including its pauses, and is never a process-wide voice cache.
@MainActor final class CookSpeechPreparation<Voice: Sendable> {
    typealias VoiceCompletion = @MainActor @Sendable ([Voice]) -> Void
    typealias AudioCompletion = @MainActor @Sendable (Bool) -> Void
    private let loadVoices: (@escaping VoiceCompletion) -> Void
    private let acquire: (UUID, @escaping AudioCompletion) -> Void
    private let release: @Sendable (UUID) -> Void
    private var generation: UUID?
    private let uniqueLeaseIDs: Bool
    private var leaseID: UUID?
    private var preparedFor: UUID?
    private var voices: [Voice] = []
    private(set) var sessionID: UUID?

    init(loadVoices: @escaping (@escaping VoiceCompletion) -> Void,
         acquire: @escaping (UUID, @escaping AudioCompletion) -> Void,
         release: @escaping @Sendable (UUID) -> Void, uniqueLeaseIDs: Bool = false) {
        self.loadVoices = loadVoices; self.acquire = acquire; self.release = release
        self.uniqueLeaseIDs = uniqueLeaseIDs
    }
    deinit { if let leaseID { release(leaseID) } }

    func prepare(for id: UUID, completion: @escaping AudioCompletion) {
        // Invalidation queues the old owner's release before any newer acquire, even for a reused id.
        releaseAudio()
        let token = UUID()
        generation = token
        sessionID = id
        leaseID = uniqueLeaseIDs ? UUID() : id
        if preparedFor == id {
            acquireAudio(for: id, token: token, completion: completion)
        } else {
            preparedFor = nil; voices = []
            loadVoices { [weak self] voices in
                guard let self, self.generation == token else { return }
                guard !voices.isEmpty else { completion(false); return }
                self.voices = voices; self.preparedFor = id
                self.acquireAudio(for: id, token: token, completion: completion)
            }
        }
    }
    private func acquireAudio(for id: UUID, token: UUID, completion: @escaping AudioCompletion) {
        guard let leaseID else { completion(false); return }
        acquire(leaseID) { [weak self] ready in
            // The matching release was already queued on invalidation. Releasing here could release
            // a newer preparation using the same playback id.
            guard let self, self.generation == token else { return }
            completion(ready)
        }
    }
    func installedVoice(localeIdentifier: String, language: (Voice) -> String) -> Voice? {
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard code == "en" || code == "es" else { return nil }
        let locale = code == "es" ? "es-US" : "en-US"
        return voices.first { language($0) == locale }
    }
    func releaseAudio() {
        generation = nil
        if let leaseID { release(leaseID) }
        leaseID = nil; sessionID = nil
    }
    func invalidate() {
        releaseAudio()
        preparedFor = nil; voices = []
    }
}

/// Shared by the real speech adapter and controlled model tests. G and L are deliberately separate;
/// even a Resume with the same G receives a unique L from CookSpeechPreparation.
@MainActor final class CookSpeechSessionBinding {
    private let audio: CookAudioSession
    private let stop: @MainActor () -> Void
    private(set) var currentIntent: UUID?
    private var preparedLease: UUID?
    init(audio: CookAudioSession, stop: @escaping @MainActor () -> Void) { self.audio = audio; self.stop = stop }
    deinit { if let currentIntent { audio.retireCook(currentIntent) } }
    func begin(_ id: UUID, changed: @escaping CookAudioSession.Change) -> Bool {
        let accepted = audio.registerCook(id, changed: changed, stop: { [weak self] acknowledge in
            changed(id)
            if self?.currentIntent == id { self?.stop() }
            acknowledge() // Matched synchronous Stop returned; not an acoustic silence guarantee.
        })
        if accepted { currentIntent = id }
        return accepted
    }
    func acquire(_ lease: UUID, completion: @escaping CookAudioSession.Completion) {
        guard let currentIntent else { completion(false); return }
        preparedLease = lease
        audio.acquireCook(currentIntent, lease: lease, completion: completion)
    }
    func intentGate(_ id: UUID) -> CookAudioGate { audio.intentGate(id) }
    func admit(_ id: UUID) -> CookAudioGate { audio.admit(id, lease: preparedLease) }
    func invalidate() { if let currentIntent { audio.invalidateCook(currentIntent) } }
    func retire() {
        if let currentIntent { audio.retireCook(currentIntent) }
        currentIntent = nil; preparedLease = nil
    }
}

// All session properties below are observed only by the serialized audio worker. Port identities
// stay in memory; no route name, UID, instruction or audio is logged or persisted.
struct CookAudioOutput: Equatable, Sendable {
    let type: String
    let uid: String
}
struct CookAudioConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let activationOptions: AVAudioSession.SetActiveOptions
}
enum CookAudioProfile: Equatable, Sendable {
    case playback, capture
    var configuration: CookAudioConfiguration {
        switch self {
        case .playback: CookAudioConfiguration(category: .playback, mode: .spokenAudio,
                                               options: [.duckOthers], activationOptions: [])
        case .capture: CookAudioConfiguration(category: .record, mode: .measurement,
                                              options: [], activationOptions: [])
        }
    }
    static func observed(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) -> CookAudioProfile? {
        // Apple documents duckOthers implicitly setting mixWithOthers. Accept precisely that
        // normalized equivalent; neither mix alone nor unrelated option flags are our profile.
        if category == .playback && mode == .spokenAudio && options.contains(.duckOthers) &&
            options.subtracting(.mixWithOthers) == [.duckOthers] { return .playback }
        if category == .record && mode == .measurement && options.isEmpty { return .capture }
        return nil
    }
}
struct CookAudioSnapshot: Equatable, Sendable {
    let outputs: [CookAudioOutput]
    let profile: CookAudioProfile?
    init(outputs: [CookAudioOutput], profile: CookAudioProfile?) {
        self.outputs = outputs.sorted { $0.type == $1.type ? $0.uid < $1.uid : $0.type < $1.type }
        self.profile = profile
    }
    var usablePlayback: Bool { profile == .playback && !outputs.isEmpty }
}
struct CookAudioBackend: Sendable {
    let activate: @Sendable (CookAudioProfile) throws -> Void
    let deactivate: @Sendable () -> Void
    let snapshot: @Sendable () throws -> CookAudioSnapshot
}
enum CookAudioGate: Equatable { case invalid, pending, ready }

/// One process-wide session owner. AV session operations and physical ownership live on queue.
/// The lock protects only logical intents, tickets and lease reservations. No native operation,
/// callback, dispatch wait or MainActor property access occurs while it is held.
final class CookAudioSession: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (Bool) -> Void
    typealias Change = @MainActor @Sendable (UUID) -> Void
    typealias Stop = @MainActor @Sendable (@escaping @Sendable () -> Void) -> Void
    static let shared = CookAudioSession(backend: CookAudioBackend(activate: { profile in
        let session = AVAudioSession.sharedInstance()
        let configuration = profile.configuration
        try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
        try session.setActive(true, options: configuration.activationOptions)
    }, deactivate: {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }, snapshot: {
        let session = AVAudioSession.sharedInstance()
        let category = session.category, mode = session.mode, options = session.categoryOptions
        let profile = CookAudioProfile.observed(category: category, mode: mode, options: options)
        return CookAudioSnapshot(outputs: session.currentRoute.outputs.map {
            CookAudioOutput(type: $0.portType.rawValue, uid: $0.uid)
        }, profile: profile)
    }))

    private struct Intent {
        var valid = true
        var baseline: CookAudioSnapshot?
        var preparedLease: UUID?
        var pending: Set<UUID> = []
        let changed: Change
        let stop: Stop
    }
    private struct Lease { let generation: UUID?; let profile: CookAudioProfile; var cancellation: CookCaptureCancellation? = nil }
    private struct PhysicalOwner { let id: UUID; let generation: UUID?; let profile: CookAudioProfile }
    private let queue = DispatchQueue(label: "dev.roominthecart.cook-audio-session", qos: .userInitiated)
    private let backend: CookAudioBackend
    private let lock = NSLock()
    private var intents: [UUID: Intent] = [:] // lock
    private var leases: [UUID: Lease] = [:] // lock
    private var captureReservation: UUID? // lock
    private var captureAcknowledgements: Set<UUID> = [] // lock
    private var owner: PhysicalOwner? // queue
    private var captureCompletions: [UUID: Completion] = [:] // queue
    private var routeObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter

    init(backend: CookAudioBackend, notificationCenter: NotificationCenter = .default) {
        self.backend = backend; self.notificationCenter = notificationCenter
        routeObserver = notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil) { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                self?.receiveRoute(reason: reason)
            }
    }
    // Compatibility façade for the original session serialization regression. Production uses
    // the profile-aware initializer and unique G/L methods below; there is still only one queue.
    convenience init(activate: @escaping @Sendable () throws -> Void, deactivate: @escaping @Sendable () -> Void) {
        self.init(backend: CookAudioBackend(activate: { _ in try activate() }, deactivate: deactivate,
            snapshot: { CookAudioSnapshot(outputs: [CookAudioOutput(type: "test", uid: "test")], profile: .playback) }),
            notificationCenter: NotificationCenter())
    }
    deinit { if let routeObserver { notificationCenter.removeObserver(routeObserver) } }

    func registerCook(_ id: UUID, changed: @escaping Change, stop: @escaping Stop) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard captureReservation == nil, !intents.contains(where: { $0.key != id && $0.value.valid }) else { return false }
        intents[id] = Intent(changed: changed, stop: stop)
        return true
    }
    func invalidateCook(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if var intent = intents[id] { intent.valid = false; intent.pending.removeAll(); intent.preparedLease = nil; intents[id] = intent }
    }
    func retireCook(_ id: UUID) {
        lock.lock()
        intents.removeValue(forKey: id)
        let owned = leases.filter { $0.value.generation == id }.map(\.key)
        for lease in owned { leases.removeValue(forKey: lease) }
        lock.unlock()
        for lease in owned { queue.async { self.releaseOnWorker(lease) } }
    }
    func intentGate(_ id: UUID) -> CookAudioGate {
        lock.lock(); defer { lock.unlock() }
        guard let intent = intents[id], intent.valid, captureReservation == nil else { return .invalid }
        return intent.pending.isEmpty ? .ready : .pending
    }
    /// Linearization point immediately before native speak/resume. No lock spans a native call.
    func admit(_ id: UUID, lease: UUID?) -> CookAudioGate {
        lock.lock(); defer { lock.unlock() }
        guard let intent = intents[id], intent.valid, captureReservation == nil else { return .invalid }
        guard intent.pending.isEmpty else { return .pending }
        guard let lease, intent.preparedLease == lease, leases[lease]?.generation == id,
              intent.baseline?.usablePlayback == true else { return .invalid }
        return .ready
    }

    private func receiveRoute(reason: UInt?) {
        let category = reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue
        var changed: [(UUID, Change)] = [], tickets: [(UUID, UUID)] = []
        lock.lock()
        for id in Array(intents.keys) {
            guard var intent = intents[id], intent.valid else { continue }
            if category && intent.pending.count < 64 {
                let ticket = UUID(); intent.pending.insert(ticket); tickets.append((id, ticket))
            } else {
                intent.valid = false; intent.pending.removeAll(); intent.preparedLease = nil
                changed.append((id, intent.changed))
            }
            intents[id] = intent
        }
        lock.unlock()
        for (id, callback) in changed { Self.deliver { callback(id) } }
        for (id, ticket) in tickets { queue.async { self.reconcile(id, ticket: ticket) } }
    }
    private static func deliver(_ action: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { action() } }
        else { DispatchQueue.main.async { action() } }
    }
    private func notify(_ id: UUID) {
        lock.lock(); let callback = intents[id]?.changed; lock.unlock()
        if let callback { Self.deliver { callback(id) } }
    }
    private func reconcile(_ id: UUID, ticket: UUID) {
        lock.lock()
        guard let intent = intents[id], intent.valid, intent.pending.contains(ticket), let baseline = intent.baseline else {
            lock.unlock(); return // Before first activation, retain ticket for its prepared baseline.
        }
        lock.unlock()
        let observed = try? backend.snapshot()
        lock.lock()
        guard var current = intents[id], current.valid, current.pending.contains(ticket) else { lock.unlock(); return }
        if observed?.usablePlayback == true && observed == baseline {
            current.pending.remove(ticket) // Never clear a newer ticket as a side effect.
        } else {
            current.valid = false; current.pending.removeAll(); current.preparedLease = nil
        }
        intents[id] = current
        lock.unlock()
        notify(id)
    }
    private func reconcilePending(_ id: UUID) {
        lock.lock(); let tickets = Array(intents[id]?.pending ?? []); lock.unlock()
        for ticket in tickets { reconcile(id, ticket: ticket) }
    }
    private func cookRequestValid(_ id: UUID, lease: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return captureReservation == nil && intents[id]?.valid == true && leases[lease]?.generation == id
    }

    func acquireCook(_ id: UUID, lease: UUID, completion: @escaping Completion) {
        lock.lock()
        let accepted = captureReservation == nil && intents[id]?.valid == true && leases[lease] == nil
        if accepted { leases[lease] = Lease(generation: id, profile: .playback) }
        lock.unlock()
        guard accepted else { Self.deliver { completion(false) }; return }
        queue.async {
            guard self.cookRequestValid(id, lease: lease), self.owner == nil else {
                self.rejectCookLease(lease); Self.deliver { completion(false) }; return
            }
            self.owner = PhysicalOwner(id: lease, generation: id, profile: .playback)
            do {
                let before = try self.backend.snapshot()
                self.lock.lock(); let baseline = self.intents[id]?.baseline; self.lock.unlock()
                if let baseline, (!before.usablePlayback || before != baseline) {
                    self.invalidateCook(id); throw CaptureFailure.audioUnavailable
                }
                try self.backend.activate(.playback)
                let after = try self.backend.snapshot()
                guard after.usablePlayback, baseline == nil || after == baseline else {
                    self.invalidateCook(id); throw CaptureFailure.audioUnavailable
                }
                guard self.cookRequestValid(id, lease: lease) else { throw CaptureFailure.audioUnavailable }
                self.lock.lock()
                if var intent = self.intents[id], intent.valid, self.captureReservation == nil,
                   self.leases[lease]?.generation == id {
                    if intent.baseline == nil { intent.baseline = after }
                    intent.preparedLease = lease; self.intents[id] = intent
                    self.lock.unlock()
                } else { self.lock.unlock(); throw CaptureFailure.audioUnavailable }
                self.reconcilePending(id)
                let ready = self.cookRequestValid(id, lease: lease)
                if !ready { self.releaseOnWorker(lease) }
                Self.deliver { completion(ready) }
            } catch {
                self.releaseOnWorker(lease)
                // A native activation failure reports unavailable through existing Bool readiness.
                // A separately revoked route/intent remains invalid; never re-arm it for failure UI.
                Self.deliver { completion(false) }
            }
        }
    }
    private func rejectCookLease(_ lease: UUID) {
        lock.lock(); leases.removeValue(forKey: lease); lock.unlock()
    }

    /// Called only after capture permissions and recognizer capability checks. Reservation revokes
    /// all live cook intents now, including voice discovery and paused speech, without AV getters.
    func acquireCapture(_ lease: UUID, cancellation: CookCaptureCancellation? = nil, completion: @escaping Completion) {
        var stops: [(UUID, Stop)] = []
        lock.lock()
        guard captureReservation == nil, cancellation?.isCancelled != true else { lock.unlock(); Self.deliver { completion(false) }; return }
        captureReservation = lease
        leases[lease] = Lease(generation: nil, profile: .capture, cancellation: cancellation)
        for id in Array(intents.keys) {
            guard var intent = intents[id] else { continue }
            intent.valid = false; intent.pending.removeAll(); intent.preparedLease = nil
            intents[id] = intent; stops.append((id, intent.stop))
        }
        captureAcknowledgements = Set(stops.map(\.0))
        lock.unlock()
        queue.async { self.captureCompletions[lease] = completion; self.tryCapture(lease) }
        for (id, stop) in stops {
            Self.deliver { [weak self] in stop { [weak self] in self?.acknowledgeCookStop(id, capture: lease) } }
        }
    }
    private func acknowledgeCookStop(_ id: UUID, capture: UUID) {
        lock.lock()
        guard captureReservation == capture else { lock.unlock(); return }
        captureAcknowledgements.remove(id)
        lock.unlock()
        queue.async { self.tryCapture(capture) }
    }
    private func captureValid(_ lease: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return captureReservation == lease && leases[lease]?.profile == .capture && leases[lease]?.cancellation?.isCancelled != true
    }
    private func tryCapture(_ lease: UUID) {
        guard captureCompletions[lease] != nil else { return }
        guard captureValid(lease) else { finishCapture(lease, ready: false); return }
        lock.lock(); let waiting = !captureAcknowledgements.isEmpty; lock.unlock()
        guard !waiting, owner == nil else { return } // Release/ack schedules continuation; never waits on main.
        owner = PhysicalOwner(id: lease, generation: nil, profile: .capture)
        do {
            try backend.activate(.capture)
            guard captureValid(lease) else { throw CancellationError() }
            finishCapture(lease, ready: true)
        } catch {
            releaseOnWorker(lease)
            finishCapture(lease, ready: false)
        }
    }
    private func finishCapture(_ lease: UUID, ready: Bool) {
        guard let completion = captureCompletions.removeValue(forKey: lease) else { return }
        Self.deliver { completion(ready) }
    }
    func release(_ lease: UUID) {
        lock.lock()
        leases.removeValue(forKey: lease)
        if captureReservation == lease { captureReservation = nil; captureAcknowledgements.removeAll() }
        for id in Array(intents.keys) where intents[id]?.preparedLease == lease { intents[id]?.preparedLease = nil }
        lock.unlock()
        queue.async { self.releaseOnWorker(lease) }
    }
    private func releaseOnWorker(_ lease: UUID) {
        if owner?.id == lease { backend.deactivate(); owner = nil }
        lock.lock()
        leases.removeValue(forKey: lease)
        if captureReservation == lease { captureReservation = nil; captureAcknowledgements.removeAll() }
        for id in Array(intents.keys) where intents[id]?.preparedLease == lease { intents[id]?.preparedLease = nil }
        let capture = captureReservation
        lock.unlock()
        finishCapture(lease, ready: false)
        if let capture { tryCapture(capture) }
    }

    // Retains the original regression's API, but is not used by production cook or capture.
    func acquire(_ id: UUID, completion: @escaping Completion) {
        queue.async {
            if self.owner == nil {
                do {
                    try self.backend.activate(.playback)
                    self.owner = PhysicalOwner(id: id, generation: nil, profile: .playback)
                } catch { Self.deliver { completion(false) }; return }
            }
            let acquired = self.owner?.id == id
            Self.deliver { completion(acquired) }
        }
    }
    /// Test synchronization only: completes after earlier worker operations without observing AV.
    func afterPendingOperations(_ completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { Self.deliver(completion) }
    }
}

/// Cancellation exists before reservation, so a cancelled Task cannot release a not-yet-created
/// lease and then accidentally acquire it. This pure flag is checked under logical ownership.
final class CookCaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }; cancelled = true; return true
    }
}
final class CookCaptureAudioRequest: Sendable {
    let id = UUID()
    private let cancellation = CookCaptureCancellation()
    private let audio: CookAudioSession
    init(audio: CookAudioSession) { self.audio = audio }
    deinit { cancel() }
    func acquire(_ completion: @escaping CookAudioSession.Completion) {
        audio.acquireCapture(id, cancellation: cancellation, completion: completion)
    }
    func cancel() { if cancellation.cancel() { audio.release(id) } }
}
