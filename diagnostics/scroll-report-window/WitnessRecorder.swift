import Foundation

struct ScrollWitnessTimestamp: Encodable {
    let absoluteTime: String
    let absoluteTimeNanoSeconds: String
    let unixSeconds: Double?
    let invalidUnixSeconds: String?

    init(absoluteTime: UInt64, absoluteTimeNanoSeconds: UInt64, unixSeconds: Double) {
        self.absoluteTime = String(absoluteTime)
        self.absoluteTimeNanoSeconds = String(absoluteTimeNanoSeconds)
        self.unixSeconds = unixSeconds.isFinite ? unixSeconds : nil
        self.invalidUnixSeconds = unixSeconds.isFinite ? nil : String(describing: unixSeconds)
    }
}

struct ScrollWitnessEvent: Encodable {
    let sequence: Int
    let instanceOrdinal: String
    let kind: String
    let callbackUptime: Double
    let callbackUnixUTC: Double
    let suppliedStart: ScrollWitnessTimestamp?
    let suppliedEnd: ScrollWitnessTimestamp?
}

struct ScrollWitnessSnapshot: Encodable {
    let schemaVersion = 1
    let diagnosticOnly = true
    let maximumRetainedEvents: Int
    let totalEvents: Int
    let omittedEvents: Int
    let totalInstances: String
    let reportCallbacks: Int
    let status: String
    let events: [ScrollWitnessEvent]
}

/// Per-test scalar storage only. No framework object survives a callback.
final class ScrollReportWindowRecorder {
    private let lock = NSLock()
    private let capacity: Int
    private var nextInstance: UInt64 = 0
    private var totalEvents = 0
    private var reportCallbacks = 0
    private var events: [ScrollWitnessEvent] = []

    init(capacity: Int = 128) {
        precondition((0...128).contains(capacity))
        self.capacity = capacity
        events.reserveCapacity(capacity)
    }

    func allocateInstance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextInstance += 1
        appendLocked(kind: "created", instance: nextInstance, start: nil, end: nil)
        return nextInstance
    }

    func record(kind: String, instance: UInt64,
                start: ScrollWitnessTimestamp? = nil, end: ScrollWitnessTimestamp? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: kind, instance: instance, start: start, end: end)
    }

    private func appendLocked(kind: String, instance: UInt64,
                              start: ScrollWitnessTimestamp?, end: ScrollWitnessTimestamp?) {
        totalEvents += 1
        if kind == "report" { reportCallbacks += 1 }
        guard events.count < capacity else { return }
        events.append(ScrollWitnessEvent(sequence: totalEvents, instanceOrdinal: String(instance), kind: kind,
            callbackUptime: ProcessInfo.processInfo.systemUptime, callbackUnixUTC: Date().timeIntervalSince1970,
            suppliedStart: start, suppliedEnd: end))
    }

    func snapshot() -> ScrollWitnessSnapshot {
        lock.lock(); defer { lock.unlock() }
        let omitted = totalEvents - events.count
        return ScrollWitnessSnapshot(maximumRetainedEvents: capacity, totalEvents: totalEvents,
            omittedEvents: omitted, totalInstances: String(nextInstance), reportCallbacks: reportCallbacks,
            status: omitted > 0 ? "truncated" : (reportCallbacks == 0 ? "no-report-callbacks" : "recorded"),
            events: events)
    }
}
