import Foundation

public struct CivilReminderTime: Codable, Equatable, Sendable {
    public let year: Int, month: Int, day: Int, hour: Int, minute: Int
    public let timeZoneID: String
    public let confirmedGMTOffset: Int?
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, timeZoneID: String, confirmedGMTOffset: Int? = nil) {
        self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute; self.timeZoneID = timeZoneID; self.confirmedGMTOffset = confirmedGMTOffset
    }
}
public struct QuietHours: Codable, Equatable, Sendable {
    public let startMinute: Int, endMinute: Int
    public init(startMinute: Int, endMinute: Int) throws {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else { throw SurfaceError.invalid }
        self.startMinute = startMinute; self.endMinute = endMinute
    }
    public func contains(hour: Int, minute: Int) -> Bool {
        let value = hour * 60 + minute
        return startMinute < endMinute ? (startMinute..<endMinute).contains(value) : value >= startMinute || value < endMinute
    }
}
public enum ReminderSubject: String, Codable, Sendable { case offer, deferral }
public struct ReminderIntent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let personaID: UUID
    public let targetID: UUID
    public let subject: ReminderSubject
    public let sourceRevision: Int64
    public let routeHandle: RouteHandle
    public let localTime: CivilReminderTime
    public let fireAt: Date
    public let expiresAt: Date
    public let cutoff: Date?
    public let quietHours: QuietHours?
    public let language: SurfaceLanguage
    public init(id: UUID = UUID(), personaID: UUID, targetID: UUID, subject: ReminderSubject, sourceRevision: Int64, routeHandle: RouteHandle,
                localTime: CivilReminderTime, expiresAt: Date, cutoff: Date? = nil, quietHours: QuietHours? = nil, language: SurfaceLanguage, now: Date) throws {
        self.id = id; self.personaID = personaID; self.targetID = targetID; self.subject = subject; self.sourceRevision = sourceRevision
        self.routeHandle = routeHandle; self.localTime = localTime; self.expiresAt = expiresAt; self.cutoff = cutoff; self.quietHours = quietHours; self.language = language
        fireAt = try ReminderPlanner.resolve(localTime)
        try validate(now: now)
    }
    public func validate(now: Date, allowPastFire: Bool = false) throws {
        guard validDate(now), validDate(fireAt), validDate(expiresAt), sourceRevision >= 0,
              cutoff.map(validDate) ?? true, subject != .offer || cutoff != nil,
              fireAt == (try ReminderPlanner.resolve(localTime)) else { throw SurfaceError.invalid }
        if let quietHours {
            _ = try QuietHours(startMinute: quietHours.startMinute, endMinute: quietHours.endMinute)
            guard !quietHours.contains(hour: localTime.hour, minute: localTime.minute) else { throw SurfaceError.quietHours }
        }
        guard fireAt < expiresAt, cutoff.map({ fireAt < $0 }) ?? true else { throw SurfaceError.expired }
        if !allowPastFire { guard fireAt > now, expiresAt > now else { throw SurfaceError.expired } }
    }
}

public enum ReminderPlanner {
    /// A DST gap is invalid; a fold needs an explicit offset chosen after preview.
    public static func resolve(_ time: CivilReminderTime) throws -> Date {
        guard (1...9998).contains(time.year), (1...12).contains(time.month), (1...31).contains(time.day), (0...23).contains(time.hour), (0...59).contains(time.minute),
              let zone = TimeZone(identifier: time.timeZoneID) else { throw SurfaceError.invalidCivilTime }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var noon = DateComponents(); noon.year = time.year; noon.month = time.month; noon.day = time.day; noon.hour = 12
        guard let midday = calendar.date(from: noon), calendar.component(.year, from: midday) == time.year,
              calendar.component(.month, from: midday) == time.month, calendar.component(.day, from: midday) == time.day else { throw SurfaceError.invalidCivilTime }
        let start = calendar.startOfDay(for: midday).addingTimeInterval(-1)
        var wanted = DateComponents(); wanted.year = time.year; wanted.month = time.month; wanted.day = time.day; wanted.hour = time.hour; wanted.minute = time.minute; wanted.second = 0
        func find(_ repeated: Calendar.RepeatedTimePolicy) -> Date? {
            guard let date = calendar.nextDate(after: start, matching: wanted, matchingPolicy: .strict, repeatedTimePolicy: repeated, direction: .forward),
                  calendar.component(.year, from: date) == time.year, calendar.component(.month, from: date) == time.month,
                  calendar.component(.day, from: date) == time.day, calendar.component(.hour, from: date) == time.hour,
                  calendar.component(.minute, from: date) == time.minute else { return nil }
            return date
        }
        guard let first = find(.first), let last = find(.last) else { throw SurfaceError.invalidCivilTime }
        if first != last {
            guard let offset = time.confirmedGMTOffset else { throw SurfaceError.ambiguousCivilTime }
            if zone.secondsFromGMT(for: first) == offset { return first }
            if zone.secondsFromGMT(for: last) == offset { return last }
            throw SurfaceError.invalidCivilTime
        }
        if let offset = time.confirmedGMTOffset, offset != zone.secondsFromGMT(for: first) { throw SurfaceError.invalidCivilTime }
        return first
    }
}

public enum ReminderStatus: String, Codable, Sendable { case desired, scheduled, permissionRequired, denied, retryNeeded, cancelled, expired }
public struct SavedReminder: Codable, Equatable, Sendable {
    public let intent: ReminderIntent
    public let version: Int64
    public let status: ReminderStatus
}
public actor ReminderStore {
    public static let maximumActive = 32
    public static let maximumRecords = 2048
    private let database: SurfaceDatabase
    public init(url: URL) throws {
        database = try SurfaceDatabase(url: url, kind: "private-reminders", schema: "CREATE TABLE reminders(id TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL);")
        // Additive migration for existing validated v1 reminder stores. The trigger
        // also protects a subsequently reopened older binary from replaying a retired ID.
        try database.transaction {
            try database.execute("CREATE TABLE IF NOT EXISTS reminder_retirements(id TEXT PRIMARY KEY NOT NULL)")
            try database.script("CREATE TRIGGER IF NOT EXISTS prevent_retired_reminder BEFORE INSERT ON reminders WHEN EXISTS(SELECT 1 FROM reminder_retirements WHERE id=NEW.id) BEGIN SELECT RAISE(ABORT,'retired'); END;")
        }
    }
    @discardableResult public func put(_ intent: ReminderIntent, expectedVersion: Int64?, now: Date) throws -> SavedReminder {
        try intent.validate(now: now)
        return try database.transaction {
            guard try database.rows("SELECT id FROM reminder_retirements WHERE id=?", [.text(intent.id.uuidString)]).isEmpty else { throw SurfaceError.stale }
            let old = try get(intent.id)
            if let old, old.intent == intent, old.status != .cancelled, old.status != .expired,
               expectedVersion == old.version || expectedVersion == (old.version == 1 ? nil : old.version - 1) { return old }
            guard old?.version == expectedVersion, (old?.version ?? 0) < Int64.max else { throw SurfaceError.stale }
            let counts = try database.rows("SELECT COUNT(*), COALESCE(SUM(CASE WHEN status NOT IN ('cancelled','expired') THEN 1 ELSE 0 END),0) FROM reminders")[0]
            guard let all = Int(counts[0] ?? ""), let active = Int(counts[1] ?? "") else { throw SurfaceError.corrupt }
            if old == nil { guard all < Self.maximumRecords else { throw SurfaceError.capacity } }
            if old == nil || old?.status == .cancelled || old?.status == .expired { guard active < Self.maximumActive else { throw SurfaceError.capacity } }
            let version = (old?.version ?? 0) + 1
            guard let body = String(data: try canonical(intent), encoding: .utf8) else { throw SurfaceError.invalid }
            try database.execute("INSERT INTO reminders VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,body=excluded.body,status=excluded.status", [.text(intent.id.uuidString), .integer(version), .text(body), .text(ReminderStatus.desired.rawValue)])
            return SavedReminder(intent: intent, version: version, status: .desired)
        }
    }
    public func get(_ id: UUID) throws -> SavedReminder? { try database.rows("SELECT id,version,body,status FROM reminders WHERE id=?", [.text(id.uuidString)]).first.map(decode) }
    public func all() throws -> [SavedReminder] { try database.rows("SELECT id,version,body,status FROM reminders ORDER BY id").map(decode) }
    @discardableResult public func cancel(_ id: UUID) throws -> SavedReminder? {
        try database.transaction {
            guard let old = try get(id) else { return nil }
            if old.status == .cancelled { return old }
            guard old.version < Int64.max else { throw SurfaceError.stale }
            try database.execute("UPDATE reminders SET version=version+1,status='cancelled' WHERE id=?", [.text(id.uuidString)])
            return try get(id)
        }
    }
    @discardableResult public func mark(_ id: UUID, version: Int64, status: ReminderStatus) throws -> Bool {
        guard ![.desired, .cancelled].contains(status) else { throw SurfaceError.invalid }
        return try database.execute("UPDATE reminders SET status=? WHERE id=? AND version=? AND status NOT IN ('cancelled','expired')", [.text(status.rawValue), .text(id.uuidString), .integer(version)]) == 1
    }
    /// Removes private metadata while retaining only a bounded opaque-ID receipt.
    /// A late initial save cannot resurrect this operation after successful erasure.
    public func eraseCancelled(_ id: UUID, version: Int64) throws { try retire(id, expectedVersion: version) }
    func eraseAbsent(_ id: UUID) throws { try retire(id, expectedVersion: nil) }
    private func retire(_ id: UUID, expectedVersion: Int64?) throws {
        try database.transaction {
            if let row = try get(id) {
                guard row.version == expectedVersion, row.status == .cancelled else { throw SurfaceError.stale }
            }
            let existing = try database.rows("SELECT id FROM reminder_retirements WHERE id=?", [.text(id.uuidString)])
            if existing.isEmpty {
                guard let count = Int(try database.rows("SELECT COUNT(*) FROM reminder_retirements")[0][0] ?? ""), count < 10_000 else { throw SurfaceError.capacity }
                try database.execute("INSERT INTO reminder_retirements(id) VALUES(?)", [.text(id.uuidString)])
            }
            try database.execute("DELETE FROM reminders WHERE id=?", [.text(id.uuidString)])
        }
    }
    private func decode(_ row: [String?]) throws -> SavedReminder {
        guard let id = UUID(uuidString: row[0] ?? ""), let version = Int64(row[1] ?? ""), version > 0,
              let body = row[2], body.utf8.count <= 16_384, let status = ReminderStatus(rawValue: row[3] ?? "") else { throw SurfaceError.corrupt }
        let intent = try JSONDecoder().decode(ReminderIntent.self, from: Data(body.utf8))
        guard intent.id == id else { throw SurfaceError.corrupt }
        try intent.validate(now: intent.fireAt, allowPastFire: true)
        return SavedReminder(intent: intent, version: version, status: status)
    }
}

public enum NotificationPermission: Sendable { case unknown, denied, authorized }
/// Allowlisted, non-private OS projection. No persona, target, source text or financial value.
public struct ReminderNotification: Equatable, Sendable {
    public let identifier: String
    public let routeHandle: RouteHandle
    public let fireAt: Date
    public let timeZoneID: String
    public let language: SurfaceLanguage
    public init(_ intent: ReminderIntent) { identifier = Self.identifier(intent.id); routeHandle = intent.routeHandle; fireAt = intent.fireAt; timeZoneID = intent.localTime.timeZoneID; language = intent.language }
    public static func identifier(_ id: UUID) -> String { "device-surfaces.reminder." + id.uuidString.lowercased() }
}
public protocol NotificationScheduling: Sendable {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func add(_ notification: ReminderNotification) async throws
    func remove(_ identifiers: [String]) async
}

/// OS operations are serialized, including across reentrant actor calls.
/// The private desired state is persisted first; a stale callback cannot publish scheduled state.
public actor ReminderCoordinator {
    private let store: ReminderStore
    private let scheduler: any NotificationScheduling
    private let now: @Sendable () -> Date
    private var tail: Task<Void, Never>?
    public init(store: ReminderStore, scheduler: any NotificationScheduling, now: @escaping @Sendable () -> Date = { Date() }) { self.store = store; self.scheduler = scheduler; self.now = now }
    public func save(_ intent: ReminderIntent, expectedVersion: Int64?, requestPermission: Bool) async throws -> SavedReminder {
        _ = try await store.put(intent, expectedVersion: expectedVersion, now: now())
        await enqueue(intent.id, requestPermission: requestPermission).value
        guard let result = try await store.get(intent.id) else { throw SurfaceError.corrupt }; return result
    }
    public func cancel(_ id: UUID) async throws {
        _ = try await store.cancel(id)
        await enqueue(id, requestPermission: false).value
    }
    /// Removal is idempotent. A concurrent new version fails rather than deleting it.
    public func erase(_ id: UUID) async throws {
        try await cancel(id)
        guard let cancelled = try await store.get(id) else { try await store.eraseAbsent(id); return }
        guard cancelled.status == .cancelled else { throw SurfaceError.stale }
        try await store.eraseCancelled(id, version: cancelled.version)
    }
    public func current(_ id: UUID) async throws -> SavedReminder? { try await store.get(id) }
    public func reconcileAll() async throws {
        for row in try await store.all() { await enqueue(row.intent.id, requestPermission: false).value }
    }
    public func cancelAll(personaID: UUID) async throws {
        for row in try await store.all() where row.intent.personaID == personaID { try await cancel(row.intent.id) }
    }
    private func enqueue(_ id: UUID, requestPermission: Bool) -> Task<Void, Never> {
        let previous = tail
        let task = Task { await previous?.value; await self.reconcile(id, requestPermission: requestPermission) }
        tail = task; return task
    }
    private func reconcile(_ id: UUID, requestPermission: Bool) async {
        let identifier = ReminderNotification.identifier(id)
        guard let row = try? await store.get(id) else { await scheduler.remove([identifier]); return }
        if row.status == .cancelled || row.status == .expired { await scheduler.remove([identifier]); return }
        do { try row.intent.validate(now: now()) }
        catch { await scheduler.remove([identifier]); _ = try? await store.mark(id, version: row.version, status: .expired); return }
        var permission = await scheduler.permission()
        if permission == .unknown, requestPermission {
            do { permission = try await scheduler.requestPermission() ? .authorized : .denied }
            catch { _ = try? await store.mark(id, version: row.version, status: .retryNeeded); return }
        }
        guard permission == .authorized else {
            await scheduler.remove([identifier]); _ = try? await store.mark(id, version: row.version, status: permission == .unknown ? .permissionRequired : .denied); return
        }
        guard let current = try? await store.get(id), current.version == row.version, current.status != .cancelled else { return }
        do {
            try await scheduler.add(ReminderNotification(row.intent))
            let marked = try await store.mark(id, version: row.version, status: .scheduled)
            if !marked { await scheduler.remove([identifier]) }
        } catch { _ = try? await store.mark(id, version: row.version, status: .retryNeeded) }
    }
}

public enum ReminderOpenOutcome: Equatable, Sendable { case unavailable, review, awaitPickup(cutoff: Date) }
public enum ReminderOpening {
    /// `authorized` and current target values come from app/service revalidation, not notification userInfo.
    public static func evaluate(intent: ReminderIntent, authorized: Bool, currentTargetID: UUID?, currentCutoff: Date?, now: Date) -> ReminderOpenOutcome {
        guard authorized, currentTargetID == intent.targetID, validDate(now) else { return .unavailable }
        if intent.subject == .offer {
            guard let cutoff = currentCutoff, validDate(cutoff) else { return .unavailable }
            return now >= cutoff ? .awaitPickup(cutoff: cutoff) : .review
        }
        return now >= intent.expiresAt ? .unavailable : .review
    }
}
