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

struct PantryFoodKeeperSelection: Codable, Equatable {
    let lotID: UUID
    let revision: Int64
    let range: FoodKeeperReviewedRange
    static let reference = try? FoodKeeperReference.bundled()

    func applies(to lot: InventoryLot) -> Bool {
        guard lot.id == lotID, lot.revision == revision, range.storage == lot.location.foodKeeperStorage,
              let reference = Self.reference else { return false }
        return range.matches(reference, asOf: range.start)
    }
}

extension InventoryLocation {
    var foodKeeperStorage: FoodKeeperStorage {
        switch self {
        case .cupboard: .pantry
        case .fridge: .refrigerator
        case .freezer: .freezer
        }
    }
}

struct PantryDigestRule: Codable, Equatable {
    enum Source: String, Codable { case foodKeeper }
    let lotID: UUID
    var revision: Int64
    let day: MealDay
    let handle: UUID
    var source: Source?
}

struct PantryDigestDocument: Codable, Equatable {
    let version: Int
    let origin: UUID
    let owner: String
    var enabled = false
    var minute = 540
    var digestZone = TimeZone.current.identifier
    var rules: [PantryDigestRule] = []
    // Optional for documents written before the offline guide could save a reviewed range.
    var foodKeeper: [PantryFoodKeeperSelection]?
    var shelf: PantryShelfCount?
    var presence: [PantryPresence]?
    var minimums: [PantryStapleMinimum]?
    var selections: [PantryFoodKeeperSelection] { foodKeeper ?? [] }

    func currentGuideRange(for lot: InventoryLot) -> FoodKeeperReviewedRange? {
        selections.first(where: { $0.applies(to: lot) })?.range
    }

    init(_ scope: PantryDigestScope) { version = 1; origin = scope.origin; owner = scope.owner }

    func validate() throws {
        guard version == 1, TimeZone(identifier: digestZone) != nil, owner.count == 64, owner.allSatisfy(\.isHexDigit), (0..<1440).contains(minute),
              rules.count <= 32, Set(rules.map(\.lotID)).count == rules.count,
              rules.allSatisfy({ $0.revision > 0 }) else { throw PantryDigestFailure.invalid }
        guard selections.count <= 32, Set(selections.map(\.lotID)).count == selections.count else { throw PantryDigestFailure.invalid }
        for choice in selections {
            let range = choice.range
            guard choice.revision > 0, range.version > 0, range.productID > 0, range.condition.storage == range.storage,
                  range.condition.startingEvent == range.event, range.start.timeZoneIdentifier == range.earliest.timeZoneIdentifier,
                  range.start.timeZoneIdentifier == range.latest.timeZoneIdentifier else { throw PantryDigestFailure.invalid }
            try range.start.validate()
            try range.earliest.validate()
            try range.latest.validate()
        }
        if let shelf {
            guard shelf.name.utf8.count <= 128, shelf.batches.count <= 128,
                  Set(shelf.batches.map(\.id)).count == shelf.batches.count,
                  shelf.batches.allSatisfy({ $0.revision > 0 }) else { throw PantryDigestFailure.invalid }
        }
        let sightings = presence ?? [], targets = minimums ?? []
        guard sightings.count <= 256, targets.count <= 64,
              Set(sightings.map(\.lotID)).count == sightings.count, Set(targets.map(\.foodID)).count == targets.count,
              sightings.allSatisfy({ $0.date.timeIntervalSinceReferenceDate.isFinite }) else { throw PantryDigestFailure.invalid }
        for target in targets {
            try target.target.validate()
            guard target.target.amount > .zero else { throw PantryDigestFailure.invalid }
        }
        let days = Dictionary(grouping: rules, by: \.day.iso8601)
        guard days.values.allSatisfy({ Set($0.map(\.handle)).count == 1 }),
              Set(rules.map(\.handle)).count == days.count else { throw PantryDigestFailure.invalid }
        for rule in rules { try rule.day.validate() }
    }

    mutating func set(lot: InventoryLot, day: MealDay?, source: PantryDigestRule.Source? = nil) throws {
        guard lot.count.quantity?.amount != .zero else { throw PantryDigestFailure.changed }
        // Handles identify calendar days, including a day whose only lot is being edited.
        let handle = day.flatMap { selected in rules.first { $0.day.hasSameCivilDate(as: selected) }?.handle }
        rules.removeAll { $0.lotID == lot.id }
        if let day {
            guard rules.count < 32 else { throw PantryDigestFailure.capacity }
            try day.validate()
            rules.append(.init(lotID: lot.id, revision: lot.revision, day: day, handle: handle ?? UUID(), source: source))
        }
        try validate()
    }

    mutating func setRange(_ range: FoodKeeperReviewedRange?, for lot: InventoryLot, today: MealDay?) throws {
        var choices = selections.filter { $0.lotID != lot.id }
        let existing = rules.first { $0.lotID == lot.id }
        if let range {
            guard let today, let reference = PantryFoodKeeperSelection.reference, range.matches(reference, asOf: today),
                  range.storage == lot.location.foodKeeperStorage, lot.count.quantity?.amount != .zero else {
                throw PantryDigestFailure.changed
            }
            guard choices.count < 32 else { throw PantryDigestFailure.capacity }
            choices.append(.init(lotID: lot.id, revision: lot.revision, range: range))
            if existing == nil || existing?.source == .foodKeeper {
                try set(lot: lot, day: range.earliest, source: .foodKeeper)
            }
        } else if existing?.source == .foodKeeper {
            try set(lot: lot, day: nil)
        }
        foodKeeper = choices.isEmpty ? nil : choices
        try validate()
    }

    mutating func reconcile(_ lots: [InventoryLot]) {
        let heads = Dictionary(uniqueKeysWithValues: lots.filter { $0.count.quantity?.amount != .zero }.map { ($0.id, $0) })
        let choices = selections.filter { heads[$0.lotID] != nil }
        foodKeeper = choices.isEmpty ? nil : choices
        rules = rules.compactMap { rule in
            guard let lot = heads[rule.lotID] else { return nil }
            if rule.source == .foodKeeper {
                guard let choice = choices.first(where: { $0.lotID == lot.id }), choice.applies(to: lot),
                      choice.range.earliest == rule.day else { return nil }
            }
            // A manual check is the shopper's own date for this surviving batch, independent of storage guidance.
            var current = rule
            current.revision = lot.revision
            return current
        }
    }

    func deliveries(now: Date) -> [PantryDigestDelivery] {
        guard enabled, let zone = TimeZone(identifier: digestZone) else { return [] }
        var seen = Set<String>()
        return rules.compactMap { rule in
            guard seen.insert(rule.day.iso8601).inserted,
                  let zonedDay = try? MealDay(year: rule.day.year, month: rule.day.month, day: rule.day.day,
                                             timeZoneIdentifier: digestZone), let noon = zonedDay.date else { return nil }
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

typealias PantryNotificationRequest = @MainActor () async throws -> Bool
typealias PantryNotificationPresenter = @MainActor (PantryNotificationRequest) async throws -> Bool

@MainActor protocol PantryDigestScheduling {
    func permission(request: Bool, presenting: PantryNotificationPresenter?) async throws -> Bool
    func replace(_ deliveries: [PantryDigestDelivery], keepingDelivered: Set<UUID>) async throws
    func remove(_ handles: Set<UUID>) async
    func prune(keepingPending: Set<UUID>, keepingDelivered: Set<UUID>) async
}

@MainActor struct PantryDigestNotifications: PantryDigestScheduling {
    static let prefix = "pantry.digest."
    typealias SystemRemoval = @Sendable (_ pending: [String], _ delivered: [String]) -> Void
    private static let removalQueue = DispatchQueue(label: "dev.roominthecart.pantry.notification-cleanup", qos: .utility)
    private let isolated: Bool
    private let removeFromSystem: SystemRemoval

    init(isolated: Bool, removeFromSystem: @escaping SystemRemoval = { pending, delivered in
        let center = UNUserNotificationCenter.current()
        if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }
        if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
    }) {
        self.isolated = isolated
        self.removeFromSystem = removeFromSystem
    }

    // UserNotifications can synchronously wait for its service. Keep the store's
    // ordering and privacy fence without making a slow service freeze the interface.
    private func retire(pending: [String] = [], delivered: [String] = []) async {
        guard !pending.isEmpty || !delivered.isEmpty else { return }
        let remove = removeFromSystem
        await withCheckedContinuation { continuation in
            Self.removalQueue.async {
                remove(pending, delivered)
                continuation.resume()
            }
        }
    }

    func permission(request: Bool, presenting: PantryNotificationPresenter?) async throws -> Bool {
        guard !isolated else { return false }
        let scheduler = IOSNotificationScheduler()
        switch await scheduler.permission() {
        case .authorized: return true
        case .denied: return false
        case .unknown:
            guard request else { return false }
            if let presenting { return try await presenting { try await scheduler.requestPermission() } }
            return try await scheduler.requestPermission()
        }
    }
    func remove(_ handles: Set<UUID>) async {
        guard !isolated, !handles.isEmpty else { return }
        let identifiers = handles.map { Self.prefix + $0.uuidString }
        await retire(pending: identifiers, delivered: identifiers)
    }
    private func identifier(_ handle: UUID) -> String { Self.prefix + handle.uuidString }

    func prune(keepingPending: Set<UUID>, keepingDelivered: Set<UUID>) async {
        guard !isolated else { return }
        let center = UNUserNotificationCenter.current()
        let pending = Set(keepingPending.map(identifier))
        let delivered = Set(keepingDelivered.map(identifier))
        let requests = await center.pendingNotificationRequests().map(\.identifier)
        await retire(pending: requests.filter { $0.hasPrefix(Self.prefix) && !pending.contains($0) })
        let notifications = await center.deliveredNotifications().map(\.request.identifier)
        await retire(delivered: notifications.filter { $0.hasPrefix(Self.prefix) && !delivered.contains($0) })
    }

    func replace(_ deliveries: [PantryDigestDelivery], keepingDelivered: Set<UUID>) async throws {
        guard !isolated else { return }
        let center = UNUserNotificationCenter.current()
        let desired = Set(deliveries.map(\.handle))
        await prune(keepingPending: desired, keepingDelivered: keepingDelivered)
        do {
            for delivery in deliveries {
                let identifier = self.identifier(delivery.handle)
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
            await retire(pending: desired.map(identifier))
            throw error
        }
    }
}

@MainActor final class PantryDigestStore: ObservableObject {
    static let shared: PantryDigestStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let isolation = SurfaceRuntimeIsolation(directory: nil, launchArguments: ProcessInfo.processInfo.arguments, applicationSupport: support)
        return PantryDigestStore(folder: isolation.directory.deletingLastPathComponent().appendingPathComponent("PantryDigests"),
                                scheduler: PantryDigestNotifications(isolated: isolation.isUITesting),
                                invalidateHome: { kind, origin, forget in
                                    try AdultHomeSummaryStore.shared.invalidate(kind, origin: origin, forget: forget)
                                })
    }()
    let packageDates: PantryPackageDateStore
    private let folder: URL
    private let scheduler: any PantryDigestScheduling
    private let now: () -> Date
    private let invalidateHome: (AdultFoodSummaryKind, UUID, Bool) throws -> Void
    private var last: Task<Void, Error>?
    @Published private(set) var generation = UUID()
    @Published var tapped: UUID?
    @Published private(set) var notificationsUnavailable = false

    init(folder: URL, scheduler: any PantryDigestScheduling, now: @escaping () -> Date = Date.init,
         invalidateHome: @escaping (AdultFoodSummaryKind, UUID, Bool) throws -> Void = { _, _, _ in }) {
        self.invalidateHome = invalidateHome
        self.folder = folder; self.scheduler = scheduler; self.now = now
        packageDates = PantryPackageDateStore(folder: folder.appendingPathComponent("PrintedDates", isDirectory: true))
    }
    private func file(_ scope: PantryDigestScope) -> URL {
        folder.appendingPathComponent(scope.origin.uuidString + "-" + scope.owner + ".json")
    }
    private func read(_ url: URL) throws -> PantryDigestDocument {
        let bytes = try PantryArchiveFiles.read(url, maximum: 262_144)
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
        try invalidateHome(.useSoon, doc.origin, false)
        try PantryArchiveFiles.directory(folder, create: true)
        let data = try JSONEncoder().encode(doc)
        guard data.count <= 262_144 else { throw PantryDigestFailure.capacity }
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
            let granted = doc?.enabled == true ? try await scheduler.permission(request: false, presenting: nil) : false
            try await scheduler.replace(granted ? doc?.deliveries(now: now()) ?? [] : [],
                                        keepingDelivered: granted ? Set(doc?.rules.map(\.handle) ?? []) : [])
            notificationsUnavailable = doc?.enabled == true && !granted
        }
    }
    private func change(_ scope: PantryDigestScope, _ mutate: (inout PantryDigestDocument) throws -> Void) async throws {
        var doc = try document(scope)
        let wasEnabled = doc.enabled
        try mutate(&doc)
        try write(doc, to: file(scope))
        if doc.enabled {
            try await schedule(doc)
        } else if wasEnabled {
            try await serialized { [scheduler] in await scheduler.remove(Set(doc.rules.map(\.handle))) }
            notificationsUnavailable = false
        }
    }
    func updateShelf(_ expected: PantryShelfCount?, next: PantryShelfCount?, sighting: UUID? = nil,
                     access: PantryDigestAccess) throws {
        guard access.authorized() else { throw PantryDigestFailure.changed }
        var doc = try document(access.scope)
        guard doc.shelf == expected else { throw PantryDigestFailure.changed }
        doc.shelf = next
        if let sighting {
            var observations = (doc.presence ?? []).filter { $0.lotID != sighting }
            observations.append(.init(lotID: sighting, date: now()))
            doc.presence = Array(observations.suffix(256))
        }
        try write(doc, to: file(access.scope))
    }

    func updateMinimum(_ expected: PantryStapleMinimum?, next: PantryStapleMinimum?, foodID: UUID,
                       access: PantryDigestAccess) throws {
        guard access.authorized() else { throw PantryDigestFailure.changed }
        var doc = try document(access.scope)
        var targets = doc.minimums ?? []
        guard targets.first(where: { $0.foodID == foodID }) == expected, next?.foodID == foodID || next == nil else {
            throw PantryDigestFailure.changed
        }
        targets.removeAll { $0.foodID == foodID }
        if let next { targets.append(next) }
        doc.minimums = targets.isEmpty ? nil : targets
        try write(doc, to: file(access.scope))
    }

    func saveDay(_ scope: PantryDigestScope, lot: InventoryLot, day: MealDay?, authorized: () -> Bool) async throws {
        guard authorized() else { throw PantryDigestFailure.changed }
        try await change(scope) { try $0.set(lot: lot, day: day) }
    }
    func saveRange(_ range: FoodKeeperReviewedRange?, scope: PantryDigestScope, lot: InventoryLot,
                   authorized: () -> Bool) async throws {
        guard authorized() else { throw PantryDigestFailure.changed }
        let today = try range.map { try MealDay(date: now(), timeZoneIdentifier: $0.start.timeZoneIdentifier) }
        try await change(scope) { try $0.setRange(range, for: lot, today: today) }
    }
    func setAlerts(_ scope: PantryDigestScope, enabled: Bool, minute: Int, timeZone: TimeZone = .current,
                   presenting: PantryNotificationPresenter? = nil, authorized: () -> Bool) async throws {
        guard authorized(), (0..<1440).contains(minute) else { throw PantryDigestFailure.changed }
        if enabled {
            let request = try !document(scope).enabled
            guard try await scheduler.permission(request: request, presenting: presenting) else { throw PantryDigestFailure.denied }
        }
        if !enabled {
            try await pruneOrphanedNotifications()
        }
        guard authorized() else { throw PantryDigestFailure.changed }
        try await change(scope) { doc in
            doc.enabled = enabled
            doc.minute = minute
            doc.digestZone = timeZone.identifier
        }
        if enabled && notificationsUnavailable { throw PantryDigestFailure.denied }
    }
    func failClosed() async {
        do { try await suspendNotifications() } catch { notificationsUnavailable = true }
    }
    private func documentURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == "json" }
    }

    /// Drop only requests absent from all enabled digests before disabling alerts or erasing their last document.
    private func pruneOrphanedNotifications() async throws {
        try await serialized { [self] in
            // Unreadable metadata cannot authorize notifications or prevent another shopper's cleanup.
            // Preserve its file and retain every handle independently verified by a readable document.
            let urls = (try? documentURLs()) ?? []
            var live = Set<UUID>()
            for url in urls {
                guard let doc = try? read(url), doc.enabled else { continue }
                live.formUnion(doc.rules.map(\.handle))
            }
            await scheduler.prune(keepingPending: live, keepingDelivered: live)
        }
    }

    func suspendNotifications() async throws {
        let documents: [PantryDigestDocument]
        do {
            documents = try documentURLs().map(read)
        } catch {
            try await schedule(nil)
            return
        }
        if documents.contains(where: \.enabled) {
            // A corrected date can reach disk before its old OS request is replaced.
            // Clear the digest namespace, including handles no longer present in these rules.
            try await schedule(nil)
        } else {
            // Manual dates work before notification permission is requested.
            let handles = Set(documents.flatMap { $0.rules.map(\.handle) })
            if !handles.isEmpty { try await serialized { [scheduler] in await scheduler.remove(handles) } }
            notificationsUnavailable = false
        }
    }
    func reconcile(_ scope: PantryDigestScope, lots: [InventoryLot]) async throws {
        var doc = try document(scope)
        let old = doc
        doc.reconcile(lots)
        if doc != old { try write(doc, to: file(scope)) }
        if doc.enabled { try await schedule(doc) }
        else { try await suspendNotifications() }
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
        if !batch.writes.isEmpty || !batch.erasures.isEmpty { try invalidateHome(.tonight, batch.workspaceID, false) }
        guard !ids.isEmpty else { return }
        try invalidateHome(.useSoon, batch.workspaceID, false)
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
        for kind in AdultFoodSummaryKind.allCases { try invalidateHome(kind, origin, whole) }
        try await packageDates.erase(origin: origin, whole: whole) { lot in
            try await inventory.inventoryRecord(.init(.lot, lot)) != nil
        }
        let urls = try documents(for: origin)
        guard !urls.isEmpty else { return }
        try await pruneOrphanedNotifications()
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
            var erasedChoices = Set<UUID>()
            for choice in doc.selections {
                if try await inventory.inventoryRecord(.init(.lot, choice.lotID)) == nil {
                    erasedChoices.insert(choice.lotID)
                }
            }
            let before = doc
            let workflowLots = Set((doc.shelf?.batches.map(\.id) ?? []) + (doc.presence?.map(\.lotID) ?? []) + (doc.minimums?.map(\.anchorLotID) ?? []))
            for id in workflowLots {
                if try await inventory.inventoryRecord(.init(.lot, id)) == nil {
                    doc.shelf?.batches.removeAll { $0.id == id }
                    doc.presence?.removeAll { $0.lotID == id }
                    doc.minimums?.removeAll { $0.anchorLotID == id }
                }
            }
            if doc.shelf?.batches.isEmpty == true { doc.shelf = nil }
            if doc != before || !removed.isEmpty || !erasedChoices.isEmpty {
                let kept = doc.selections.filter { !erasedChoices.contains($0.lotID) }
                doc.foodKeeper = kept.isEmpty ? nil : kept
                doc.rules.removeAll { removed.contains($0.lotID) }
                let retired = prior.subtracting(doc.rules.map(\.handle))
                try await serialized { [scheduler] in await scheduler.remove(retired) }
                try write(doc, to: url)
            }
        }
        generation = UUID()
    }
}
