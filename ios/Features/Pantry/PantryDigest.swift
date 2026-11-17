import Foundation
import CoreDomain
import CryptoKit
import DeviceSurfaces
import LocalStore
import SwiftUI
import UserNotifications

struct PantryDigestScope: Equatable {
    let origin: UUID
    let owner: String

    init(origin: UUID, identity: CapturePrivateIdentity) {
        self.origin = origin
        let fields: [String?] = [identity.actorID.uuidString, identity.subject, identity.householdID, identity.memberID, identity.role]
        var hash = SHA256()
        for field in fields {
            guard let field else { hash.update(data: Data([0])); continue }
            let bytes = Data(field.utf8)
            hash.update(data: Data(("1" + String(bytes.count) + ",").utf8))
            hash.update(data: bytes)
        }
        owner = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct PantryDigestRule: Codable, Equatable {
    let lotID: UUID
    let revision: Int64
    let day: MealDay
    let handle: UUID
}

struct PantryDigestDocument: Codable, Equatable {
    let version: Int
    let origin: UUID
    let owner: String
    var enabled = false
    var minute = 540
    var rules: [PantryDigestRule] = []

    init(_ scope: PantryDigestScope) { version = 1; origin = scope.origin; owner = scope.owner }

    func validate() throws {
        guard version == 1, owner.count == 64, owner.allSatisfy(\.isHexDigit), (0..<1440).contains(minute),
              rules.count <= 32, Set(rules.map(\.lotID)).count == rules.count,
              rules.allSatisfy({ $0.revision > 0 }) else { throw PantryDigestFailure.invalid }
        let days = Dictionary(grouping: rules, by: \.day)
        guard days.values.allSatisfy({ Set($0.map(\.handle)).count == 1 }),
              Set(rules.map(\.handle)).count == days.count else { throw PantryDigestFailure.invalid }
        for rule in rules { try rule.day.validate() }
    }

    mutating func set(lot: InventoryLot, day: MealDay?) throws {
        guard lot.count.quantity?.amount != .zero else { throw PantryDigestFailure.changed }
        rules.removeAll { $0.lotID == lot.id }
        if let day {
            guard rules.count < 32 else { throw PantryDigestFailure.capacity }
            try day.validate()
            let existing = rules.first { $0.day == day }
            rules.append(.init(lotID: lot.id, revision: lot.revision, day: day, handle: existing?.handle ?? UUID()))
        }
        try validate()
    }

    mutating func reconcile(_ lots: [InventoryLot]) {
        let heads = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0) })
        rules.removeAll { rule in
            guard let lot = heads[rule.lotID] else { return true }
            return lot.revision != rule.revision || lot.count.quantity?.amount == .zero
        }
    }

    func deliveries(now: Date) -> [PantryDigestDelivery] {
        guard enabled else { return [] }
        var seen = Set<MealDay>()
        return rules.compactMap { rule in
            guard seen.insert(rule.day).inserted, let zone = TimeZone(identifier: rule.day.timeZoneIdentifier),
                  let noon = rule.day.date else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: noon,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                calendar.isDate(date, inSameDayAs: noon), date > now else { return nil }
            return PantryDigestDelivery(handle: rule.handle, date: date, zone: zone)
        }.sorted { $0.date < $1.date }
    }
}

enum PantryDigestFailure: Error { case invalid, changed, denied, capacity }
struct PantryDigestDelivery: Equatable { let handle: UUID; let date: Date; let zone: TimeZone }

@MainActor protocol PantryDigestScheduling {
    func permission(request: Bool) async throws -> Bool
    func replace(_ deliveries: [PantryDigestDelivery], keepingDelivered: Set<UUID>) async throws
    func remove(_ handles: Set<UUID>) async
}

@MainActor struct PantryDigestNotifications: PantryDigestScheduling {
    static let prefix = "pantry.digest."
    let isolated: Bool
    func permission(request: Bool) async throws -> Bool {
        guard !isolated else { return false }
        let scheduler = IOSNotificationScheduler()
        switch await scheduler.permission() {
        case .authorized: return true
        case .denied: return false
        case .unknown: return request ? try await scheduler.requestPermission() : false
        }
    }
    func remove(_ handles: Set<UUID>) async {
        guard !isolated, !handles.isEmpty else { return }
        let identifiers = handles.map { Self.prefix + $0.uuidString }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func replace(_ deliveries: [PantryDigestDelivery], keepingDelivered: Set<UUID>) async throws {
        guard !isolated else { return }
        let center = UNUserNotificationCenter.current()
        func id(_ handle: UUID) -> String { Self.prefix + handle.uuidString }
        let desired = Set(deliveries.map { id($0.handle) })
        let prior = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: prior.filter { !desired.contains($0) })
        let keep = Set(keepingDelivered.map(id))
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(Self.prefix) && !keep.contains($0) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        do {
            for delivery in deliveries {
                let identifier = id(delivery.handle)
                var calendar = Calendar(identifier: .gregorian)
                guard let offset = TimeZone(secondsFromGMT: delivery.zone.secondsFromGMT(for: delivery.date)) else { throw PantryDigestFailure.invalid }
                calendar.timeZone = offset
                var parts = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: delivery.date)
                parts.calendar = calendar; parts.timeZone = calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                guard let next = trigger.nextTriggerDate(), abs(next.timeIntervalSince(delivery.date)) < 1 else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Room in the Cart"
                content.body = pantryText("Open My Pantry to review the foods you chose to check.")
                content.sound = .default
                content.userInfo = ["pantryDigest": delivery.handle.uuidString]
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            }
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: Array(desired))
            throw error
        }
    }
}

@MainActor final class PantryDigestStore: ObservableObject {
    static let shared: PantryDigestStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let isolation = SurfaceRuntimeIsolation(directory: nil, launchArguments: ProcessInfo.processInfo.arguments, applicationSupport: support)
        return PantryDigestStore(folder: isolation.directory.deletingLastPathComponent().appendingPathComponent("PantryDigests"),
                                scheduler: PantryDigestNotifications(isolated: isolation.isUITesting))
    }()
    private let folder: URL
    private let scheduler: any PantryDigestScheduling
    private let now: () -> Date
    private var last: Task<Void, Error>?
    @Published private(set) var generation = UUID()
    @Published var tapped: UUID?
    @Published private(set) var notificationsUnavailable = false

    init(folder: URL, scheduler: any PantryDigestScheduling, now: @escaping () -> Date = Date.init) {
        self.folder = folder; self.scheduler = scheduler; self.now = now
    }
    private func file(_ scope: PantryDigestScope) -> URL {
        folder.appendingPathComponent(scope.origin.uuidString + "-" + scope.owner + ".json")
    }
    private func read(_ url: URL) throws -> PantryDigestDocument {
        let bytes = try PantryArchiveFiles.read(url, maximum: 32_768)
        let doc = try JSONDecoder().decode(PantryDigestDocument.self, from: bytes)
        try doc.validate()
        return doc
    }
    func document(_ scope: PantryDigestScope) throws -> PantryDigestDocument {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(scope) }
        let doc = try read(url)
        guard doc.origin == scope.origin, doc.owner == scope.owner else { throw PantryDigestFailure.invalid }
        return doc
    }
    private func write(_ doc: PantryDigestDocument, to url: URL) throws {
        try doc.validate()
        try PantryArchiveFiles.directory(folder, create: true)
        let data = try JSONEncoder().encode(doc)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try PantryArchiveFiles.protect(url, permissions: 0o600)
        generation = UUID()
    }
    /// Serialize the entire asynchronous remove/replace operation across scenes, including late permission callbacks.
    private func serialized(_ perform: @escaping @MainActor () async throws -> Void) async throws {
        let prior = last
        let task = Task {
            _ = await prior?.result
            try await perform()
        }
        last = task
        try await task.value
    }
    private func schedule(_ doc: PantryDigestDocument?) async throws {
        try await serialized { [self] in
            let granted = doc?.enabled == true ? try await scheduler.permission(request: false) : false
            try await scheduler.replace(granted ? doc?.deliveries(now: now()) ?? [] : [],
                                        keepingDelivered: granted ? Set(doc?.rules.map(\.handle) ?? []) : [])
            notificationsUnavailable = doc?.enabled == true && !granted
        }
    }
    private func change(_ scope: PantryDigestScope, _ mutate: (inout PantryDigestDocument) throws -> Void) async throws {
        var doc = try document(scope)
        try mutate(&doc)
        try write(doc, to: file(scope))
        try await schedule(doc)
    }
    func saveDay(_ scope: PantryDigestScope, lot: InventoryLot, day: MealDay?, authorized: () -> Bool) async throws {
        guard authorized() else { throw PantryDigestFailure.changed }
        try await change(scope) { try $0.set(lot: lot, day: day) }
    }
    func setAlerts(_ scope: PantryDigestScope, enabled: Bool, minute: Int, authorized: () -> Bool) async throws {
        guard authorized(), (0..<1440).contains(minute) else { throw PantryDigestFailure.changed }
        if enabled {
            let request = try !document(scope).enabled
            guard try await scheduler.permission(request: request) else { throw PantryDigestFailure.denied }
        }
        guard authorized() else { throw PantryDigestFailure.changed }
        try await change(scope) { doc in
            doc.enabled = enabled
            doc.minute = minute
        }
        if enabled && notificationsUnavailable { throw PantryDigestFailure.denied }
    }
    func failClosed() async {
        do { try await suspendNotifications() } catch { notificationsUnavailable = true }
    }
    func suspendNotifications() async throws { try await schedule(nil) }
    func reconcile(_ scope: PantryDigestScope, lots: [InventoryLot]) async throws {
        var doc = try document(scope)
        let old = doc
        doc.reconcile(lots)
        if doc != old { try write(doc, to: file(scope)) }
        try await schedule(doc)
    }

    private func documents(for origin: UUID) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(origin.uuidString + "-") }
    }

    /// Retire a last eligible item's notification before the physical write can become durable.
    /// If the write does not commit, foreground reconciliation can restore the original group.
    func beforeLotCommit(_ batch: InventoryBatch) async throws {
        let ids = Set(batch.writes.filter { $0.record.key.kind == .lot && $0.expectedRevision > 0 }.map(\.record.key.id) +
                      batch.erasures.filter { $0.key.kind == .lot }.map(\.key.id))
        guard !ids.isEmpty else { return }
        for url in try documents(for: batch.workspaceID) {
            let doc = try read(url)
            guard doc.origin == batch.workspaceID else { throw PantryDigestFailure.invalid }
            let remaining = Set(doc.rules.filter { !ids.contains($0.lotID) }.map(\.handle))
            let affected = Set(doc.rules.map(\.handle)).subtracting(remaining)
            if !affected.isEmpty {
                try await serialized { [scheduler] in await scheduler.remove(affected) }
            }
        }
    }

    /// Called from the receipt-bound erasure cleanup, including recovery after process death.
    func erase(origin: UUID, whole: Bool, inventory: ComparisonStore) async throws {
        let urls = try documents(for: origin)
        guard !urls.isEmpty else { return }
        for url in urls {
            var doc = try read(url)
            guard doc.origin == origin else { throw PantryDigestFailure.invalid }
            let prior = Set(doc.rules.map(\.handle))
            if whole {
                try await serialized { [scheduler] in await scheduler.remove(prior) }
                try FileManager.default.removeItem(at: url)
                continue
            }
            var removed = Set<UUID>()
            for rule in doc.rules {
                if try await inventory.inventoryRecord(.init(.lot, rule.lotID))?.revision != rule.revision { removed.insert(rule.lotID) }
            }
            if !removed.isEmpty {
                doc.rules.removeAll { removed.contains($0.lotID) }
                let retired = prior.subtracting(doc.rules.map(\.handle))
                try await serialized { [scheduler] in await scheduler.remove(retired) }
                try write(doc, to: url)
            }
        }
        generation = UUID()
    }
}
