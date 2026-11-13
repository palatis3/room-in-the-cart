// Scratch state/ordering prototype. No AVFoundation, thread creation or native audio calls.
import Foundation

enum PrototypeSpeechState: Equatable { case stopped, preparing, speaking, pausing, paused, stopping }
enum PrototypeSpeechAction: Equatable, Sendable { case start(String), pause, resume, stop }
struct PrototypeSpeechCommand: Equatable, Sendable {
    let generation: UUID
    let sequence: UInt64
    let action: PrototypeSpeechAction
}
struct PrototypeSpeechResult: Sendable {
    let command: PrototypeSpeechCommand
    let succeeded: Bool
}

/// Value-only admission reducer, not a thread-safe bridge. The eventual transport
/// must serialize these mutations independently of a blocked native owner call.
struct PrototypeSpeechMailbox {
    private(set) var generation: UUID?
    private(set) var revoked = false
    private(set) var lastAcceptedSequence: UInt64 = 0
    private(set) var pending: [PrototypeSpeechCommand] = []
    private(set) var inFlight: PrototypeSpeechCommand?

    mutating func open(_ id: UUID) -> Bool {
        guard generation == nil, inFlight == nil, pending.isEmpty else { return false }
        generation = id; revoked = false; lastAcceptedSequence = 0; return true
    }
    @discardableResult mutating func enqueue(_ command: PrototypeSpeechCommand) -> Bool {
        guard generation == command.generation, !revoked, command.action != .stop,
              command.sequence > lastAcceptedSequence, pending.count < 4 else { return false }
        lastAcceptedSequence = command.sequence
        pending.append(command); return true
    }
    @discardableResult mutating func revokeAndStop(_ command: PrototypeSpeechCommand) -> Bool {
        guard command.action == .stop, generation == command.generation,
              command.sequence > lastAcceptedSequence else { return false }
        lastAcceptedSequence = command.sequence; revoked = true
        pending = [command] // Discard queued text/Resume; never alter an in-flight API call.
        return true
    }
    mutating func admitNext() -> PrototypeSpeechCommand? {
        guard inFlight == nil else { return nil }
        while !pending.isEmpty {
            let command = pending.removeFirst()
            guard command.generation == generation, !revoked || command.action == .stop else { continue }
            inFlight = command; return command
        }
        return nil
    }
    mutating func returned(_ result: PrototypeSpeechResult) {
        precondition(result.command == inFlight)
        inFlight = nil
        if result.command.action == .stop && result.succeeded {
            pending.removeAll(); generation = nil
        }
        // A failed Stop retains the revoked generation; no replacement can open.
    }
}

@MainActor protocol PrototypeSpeechTransport: AnyObject {
    var onResult: (@MainActor (PrototypeSpeechResult) -> Void)? { get set }
    func openGeneration(_ id: UUID) -> Bool
    func prepareAudio(lease: UUID, completion: @escaping @MainActor (Bool) -> Void)
    func releaseAudio(lease: UUID)
    func enqueue(_ command: PrototypeSpeechCommand)
    func revokeAndStop(_ command: PrototypeSpeechCommand)
}

/// No framework command runs here. Stop invalidation is immediate but stopped
/// requires a native-owner result; canStart is false throughout that barrier.
@MainActor final class PrototypeSpeechCoordinator {
    private(set) var state = PrototypeSpeechState.stopped
    private(set) var closed = false
    private(set) var unavailable = false
    private(set) var generation: UUID?
    private(set) var audioLease: UUID?
    private var sequence: UInt64 = 0
    private var pendingOperation: PrototypeSpeechCommand?
    private var awaitingAudioLease: UUID?
    private let transport: any PrototypeSpeechTransport
    private let allowedToStart: () -> Bool
    private let allowedToContinue: () -> Bool

    init(transport: any PrototypeSpeechTransport,
         allowedToStart: @escaping () -> Bool, allowedToContinue: @escaping () -> Bool) {
        self.transport = transport
        self.allowedToStart = allowedToStart; self.allowedToContinue = allowedToContinue
        transport.onResult = { [weak self] in self?.received($0) }
    }
    var canStart: Bool { !closed && state == .stopped && allowedToStart() }
    @discardableResult func play(_ exactConfirmedText: String) -> Bool {
        guard canStart else { return false }
        let id = UUID()
        guard transport.openGeneration(id) else { return false }
        generation = id; unavailable = false
        prepare(.start(exactConfirmedText), id: id)
        return true
    }
    func pause() {
        guard state == .speaking, let id = generation else { return }
        guard allowedToContinue() else { stop(); return }
        let command = command(.pause, id: id)
        pendingOperation = command; state = .pausing
        transport.enqueue(command)
    }
    func resume() {
        guard state == .paused, let id = generation else { return }
        guard allowedToContinue() else { stop(); return }
        prepare(.resume, id: id)
    }
    func checkAuthority() { if !allowedToContinue() { stop() } }
    func stop() {
        guard let id = generation, state != .stopping else { return }
        let command = command(.stop, id: id)
        // Establish revocation and the barrier before invoking any callback-capable bridge.
        pendingOperation = command; awaitingAudioLease = nil; state = .stopping
        transport.revokeAndStop(command)
        releaseAudio()
    }
    func close() { closed = true; stop() }
    private func command(_ action: PrototypeSpeechAction, id: UUID) -> PrototypeSpeechCommand {
        precondition(sequence != .max); sequence += 1
        return .init(generation: id, sequence: sequence, action: action)
    }
    private func prepare(_ action: PrototypeSpeechAction, id: UUID) {
        let operation = command(action, id: id), lease = UUID()
        pendingOperation = operation; state = .preparing; audioLease = lease; awaitingAudioLease = lease
        transport.prepareAudio(lease: lease) { [weak self] ready in
            guard let self else { return }
            guard self.generation == id, self.pendingOperation == operation, self.state == .preparing else {
                // Unique lease, so disposing this stale completion cannot release a newer owner.
                if self.audioLease != lease { self.transport.releaseAudio(lease: lease) }
                return
            }
            // Claim this completion before enqueue. Until native acknowledgment,
            // state remains preparing, so state alone does not deduplicate delivery.
            guard self.awaitingAudioLease == lease else { return }
            self.awaitingAudioLease = nil
            let permitted: Bool
            switch action { case .start: permitted = self.allowedToStart(); default: permitted = self.allowedToContinue() }
            guard ready && permitted && !self.closed else {
                self.unavailable = !ready; self.stop(); return
            }
            self.transport.enqueue(operation)
        }
    }
    private func releaseAudio() {
        guard let lease = audioLease else { return }
        audioLease = nil; transport.releaseAudio(lease: lease)
    }
    private func received(_ result: PrototypeSpeechResult) {
        guard result.command.generation == generation, result.command == pendingOperation else { return }
        if result.command.action == .stop {
            guard result.succeeded else { unavailable = true; return } // Remain stopping; no retry/new engine.
            pendingOperation = nil; generation = nil; state = .stopped
            return
        }
        guard result.succeeded else { unavailable = true; stop(); return }
        guard !closed && allowedToContinue() else { stop(); return }
        pendingOperation = nil
        switch result.command.action {
        case .start, .resume: state = .speaking
        case .pause: state = .paused; releaseAudio()
        case .stop: preconditionFailure("handled above")
        }
    }
}
