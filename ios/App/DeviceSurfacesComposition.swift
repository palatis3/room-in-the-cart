import Foundation
import Combine
import SwiftUI
import WidgetKit
import CryptoKit
import CoreDomain
import DeviceSurfaces

@MainActor final class DeviceSurfacesComposition: ObservableObject {
    @Published private(set) var entries: [SelectedTextEntry] = []
    @Published var draft: SurfaceImportDraft? {
        didSet { if draft == nil { reviewBaseline = nil } }
    }
    struct DestinationChange {
        let entry: SelectedTextEntry
        let shopID: UUID
        let previous: SurfaceImportDraft
    }
    @Published var destinationChange: DestinationChange?
    private var reviewBaseline: SurfaceImportDraft?
    @Published var destination: SurfacePresentedDestination?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var available = false
    @Published private(set) var inboxAvailable = false
    private(set) var reminders: ReminderCoordinator?
    private(set) var reminderStore: ReminderStore?
    private var inbox: SelectedTextInbox?
    private var journal: SurfaceImportJournal?
    private var routes: SurfaceRouteStore?
    private var bridge: SurfaceImportBridge?
    private var projection: WidgetProjectionFile?
    private var urls: SurfaceURLCodec?
    private weak var ledger: LedgerModel?
    private weak var pickup: PickupModel?
    private weak var household: HouseholdModel?
    private weak var access: WorkspaceAccess?
    private var subscriptions = Set<AnyCancellable>()
    private var nonce = UUID()
    private var authorityKey: String?
    private var ownRequestPersona: DeviceReminderPersona?
    private var reminderPersona: DeviceReminderPersona?
    private var reminderSaveGeneration = UUID()
    private var pendingReminderCancellation = false
    private var pickupWorkspaceID: UUID?
    private var active = true
    private var reconciling = false
    private var reconcileAgain = false
    private enum Shortcut {
        case capture, current(RouteHandle)
    }
    private var pendingShortcut: Shortcut?
    private var pendingHandle: RouteHandle?
    private var pendingReminderTap: RouteHandle?
    private let directory: URL
    private let runtime: SurfaceRuntimeIsolation
    private let bundle: Bundle
    private let captureRequests: SurfaceCaptureRequests
    private let clock: () -> Date
    private let reminderScheduler: (any NotificationScheduling)?

    init(directory: URL? = nil, bundle: Bundle = .main, clock: @escaping () -> Date = Date.init,
         launchArguments: [String] = ProcessInfo.processInfo.arguments, reminderScheduler: (any NotificationScheduling)? = nil,
         captureRequests: SurfaceCaptureRequests? = nil) {
        let runtime = SurfaceRuntimeIsolation(directory: directory, launchArguments: launchArguments,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        self.runtime = runtime; self.directory = runtime.directory
        self.bundle = bundle; self.clock = clock
        self.reminderScheduler = reminderScheduler
        self.captureRequests = captureRequests ?? .shared
    }
    var privateAuthorized: Bool { active && hasAdultAuthority }
    private var hasAdultAuthority: Bool {
        guard let access, access.unlocked, let household else { return false }
        if let role = household.projection?.role, !["shopper", "organizer"].contains(role) { return false }
        return !household.locked
    }
    private var currentOwnRequestPersona: DeviceReminderPersona? {
        guard let household, household.projection?.role == "contributor", !household.locked else { return nil }
        return household.deviceReminderPersona
    }
    private var preservesOwnRequest: Bool {
        guard case .ownRequest = destination, let ownRequestPersona else { return false }
        return ownRequestPersona == currentOwnRequestPersona
    }
    var scope: SurfaceImportScope? {
        guard privateAuthorized, let ledger, ledger.ready, !ledger.hasPendingLedgerDeletion, let workspace = ledger.sourceWorkspaceID, let access else { return nil }
        return SurfaceImportScope(personaID: access.localActorID, workspaceID: workspace)
    }
    var generation: UUID? { scope == nil ? nil : nonce }
    var hasPendingSave: Bool { ledger?.hasPendingSave ?? true }
    var shops: [ShoppingLedger] { privateAuthorized ? ledger?.workspace.shops ?? [] : [] }
    func shop(_ id: UUID) -> ShoppingLedger? { guard scope != nil else { return nil }; return ledger?.workspace.shops.first { $0.id == id } }
    func bind(ledger: LedgerModel, pickup: PickupModel, household: HouseholdModel, access: WorkspaceAccess, sceneActive: Bool = true) {
        guard self.ledger == nil else { return }
        active = sceneActive
        self.ledger = ledger; self.pickup = pickup; self.household = household; self.access = access
        func changes<Value: Equatable>(_ values: some Publisher<Value, Never>) -> AnyPublisher<Void, Never> {
            values.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        // Reconcile committed ledger state and transitions that gate it. Typing
        // in list search and changing form errors have no device-surface effect.
        let ledgerChanges = Publishers.MergeMany(
            changes(ledger.$ready), changes(ledger.$saving), changes(ledger.$hasPendingSave),
            changes(ledger.$hasPendingLedgerDeletion), changes(ledger.$sourceWorkspaceID),
            changes(ledger.$revision), changes(ledger.$workspace.map(\.selectedShopID))
        ).eraseToAnyPublisher()
        for publisher in [ledgerChanges, pickup.objectWillChange.eraseToAnyPublisher(), household.objectWillChange.eraseToAnyPublisher(), access.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in Task { @MainActor in await self?.sourceDidChange() } }.store(in: &subscriptions)
        }
        captureRequests.$pending.filter { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.captureRequests.takePending() else { return }
            self.receive(.capture)
        }.store(in: &subscriptions)
        // Adult links drain after store reconciliation. An invited contributor
        // can open their own request without opening the adult stores.
        if let pendingShortcut, !hasAdultAuthority {
            self.pendingShortcut = nil
            receive(pendingShortcut)
        }
        Task { await sourceDidChange() }
    }
    private func configure() throws {
        if routes != nil { return }
        try runtime.resetOwnedTestDirectory()
        let openedJournal = try SurfaceImportJournal(directory: directory.appendingPathComponent("Reviews", isDirectory: true))
        let openedRoutes = try SurfaceRouteStore(url: directory.appendingPathComponent("routes.json"))
        let reminderStore = try ReminderStore(url: directory.appendingPathComponent("reminders.sqlite"))
        self.journal = openedJournal; self.routes = openedRoutes
        self.reminderStore = reminderStore
        reminders = ReminderCoordinator(store: reminderStore, scheduler: reminderScheduler ?? runtime.makeScheduler { IOSNotificationScheduler() })
        // UI tests never resolve an App Group, even when the real bundle is configured.
        if runtime.isUITesting {
            inbox = try runtime.makeInbox { throw SurfaceError.unconfigured }
            projection = try runtime.makeWidget { throw SurfaceError.unconfigured }
            urls = try? IOSSurfaceContainers.urls(bundle: bundle)
        } else if let config = try? SurfaceConfiguration(inboxGroup: bundle.object(forInfoDictionaryKey: SurfaceInfo.inboxGroupKey) as? String,
            widgetGroup: bundle.object(forInfoDictionaryKey: SurfaceInfo.widgetGroupKey) as? String, urlScheme: bundle.object(forInfoDictionaryKey: SurfaceInfo.schemeKey) as? String) {
            urls = config.urls
            inbox = try? IOSSurfaceContainers.inbox(bundle: bundle)
            if let widgetDirectory = try? IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey, bundle: bundle) { projection = try? WidgetProjectionFile(directory: widgetDirectory) }
        }
        if let inbox, let journal, let ledger {
            let port = LedgerSelectedTextPort(ledger: ledger, scope: { [weak self] in self?.scope }, generation: { [weak self] in self?.generation })
            bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: clock)
        }
        available = true; inboxAvailable = inbox != nil
    }
    func foreground() async { active = true; await sourceDidChange() }
    func background() {
        active = false; nonce = UUID(); entries = []; draft = nil; destinationChange = nil; destination = nil; pendingShortcut = nil; pendingHandle = nil
        ownRequestPersona = nil
        if ledger != nil { captureRequests.takePending() }
        // A cold child/locked launch may never open the adult stores. Resolve
        // only the widget file so a prior process's shortcut is still cleared.
        if projection == nil {
            if runtime.isUITesting {
                projection = try? runtime.makeWidget { throw SurfaceError.unconfigured }
            } else if let widgetDirectory = try? IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey, bundle: bundle) {
                projection = try? WidgetProjectionFile(directory: widgetDirectory)
            }
        }
        // A locked snapshot is generic even if the containing process is then suspended.
        try? projection?.clear(now: clock()); runtime.performSystemEffect { WidgetCenter.shared.reloadTimelines(ofKind: "RoomInTheCartCapture") }
    }
    func scopeChanged() {
        nonce = UUID(); entries = []; draft = nil; destinationChange = nil; destination = nil; pendingShortcut = nil; pendingHandle = nil
        ownRequestPersona = nil
        if ledger != nil { captureRequests.takePending() }
        pendingReminderTap = nil; authorityKey = nil; reminderSaveGeneration = UUID()
        Task { await sourceDidChange() }
    }
    func receiveReminderTap(_ handle: RouteHandle) {
        pendingReminderTap = handle
        pendingShortcut = nil; pendingHandle = nil
        Task { await sourceDidChange() }
    }
    private func sourceSnapshot() -> SurfaceSourceSnapshot {
        SurfaceSourceSnapshot(ledgerReady: ledger?.ready == true, pickupReady: pickup?.ready == true,
            ledgerSaving: ledger?.saving ?? true, pickupSaving: pickup?.saving ?? true,
            ledgerHasPendingSave: ledger?.hasPendingSave ?? true, pickupHasPendingSave: pickup?.hasPendingSave ?? true,
            ledgerHasPendingDeletion: ledger?.hasPendingLedgerDeletion ?? true, ledgerWorkspaceID: ledger?.sourceWorkspaceID,
            ledgerRevision: ledger?.revision ?? -1, pickupRevisions: Dictionary(uniqueKeysWithValues: (pickup?.journeys ?? []).map { ($0.id, $0.revision) }))
    }
    func sourceDidChange() async {
        if reconciling { reconcileAgain = true; return }
        reconciling = true
        defer { reconciling = false; if reconcileAgain { reconcileAgain = false; Task { await sourceDidChange() } } }
        let key = [String(privateAuthorized), household?.identity?.subject ?? "", household?.projection?.memberId ?? "", household?.projection?.role ?? "", ledger?.sourceWorkspaceID?.uuidString ?? ""].joined(separator: "|")
        if key != authorityKey {
            authorityKey = key; nonce = UUID(); entries = []; draft = nil; destinationChange = nil
            // Initial binding must not erase an explicit entry for the same
            // live contributor. Identity or authority loss still clears it.
            if !preservesOwnRequest { destination = nil; ownRequestPersona = nil }
        }
        let currentReminderPersona = household?.deviceReminderPersona
        if let previous = reminderPersona, previous != currentReminderPersona {
            pendingReminderTap = nil
            pendingReminderCancellation = true
            reminderSaveGeneration = UUID()
        }
        reminderPersona = currentReminderPersona
        if pendingReminderCancellation, let reminders, let persona = access?.localActorID {
            do { try await reminders.cancelAll(personaID: persona) }
            catch { entries = []; draft = nil; destination = nil; message = SurfaceCopy.text("Device shortcuts could not refresh. Try again."); return }
            guard currentReminderPersona == household?.deviceReminderPersona else { return }
            pendingReminderCancellation = false
        }
        guard privateAuthorized else {
            if !hasAdultAuthority { pendingShortcut = nil }
            entries = []; draft = nil
            if !preservesOwnRequest { destination = nil; ownRequestPersona = nil }
            try? projection?.clear(now: clock()); return
        }
        // Root binds before opening either model. No cleanup may treat that
        // incomplete (or uncertain-save) projection as an empty durable workspace.
        let sources = sourceSnapshot()
        guard sources.permitsReconciliation else { entries = []; return }
        let checkpoint = SurfaceReconciliationGate(expected: sources)
        let start = nonce
        func requireCurrent() throws {
            try checkpoint.requireCurrent(sourceSnapshot())
            guard generation == start, currentReminderPersona == household?.deviceReminderPersona else { throw SurfaceError.stale }
        }
        do {
            try configure()
            guard let ledger, let pickup else { throw SurfaceError.unavailable }
            if pendingReminderCancellation, let reminders, let persona = access?.localActorID {
                try await reminders.cancelAll(personaID: persona)
                try requireCurrent()
                pendingReminderCancellation = false
            }
            let retiredIDs = try await ledger.retiredLedgerWorkspaceIDs()
            try requireCurrent()
            let pickupSnapshot = try await pickup.archiveSnapshot()
            try requireCurrent()
            let pickupTombstones = try await pickup.archiveTombstones()
            try requireCurrent()
            pickupWorkspaceID = pickupSnapshot.workspaceID
            for id in retiredIDs {
                try requireCurrent()
                try await eraseLedgerWorkspace(id)
            }
            for tombstone in pickupTombstones {
                try requireCurrent()
                try await erasePickupRecord(workspaceID: tombstone.workspaceID, recordID: tombstone.id)
            }
            try requireCurrent()
            for row in try routes?.all() ?? [] {
                try requireCurrent()
                if !validTarget(row, requireRevision: row.reminderID != nil) { try await removeRoute(row) }
            }
            try requireCurrent()
            let referencedReminders = Set(try routes?.all().compactMap(\.reminderID) ?? [])
            for reminder in try await reminderStore?.all() ?? [] where !referencedReminders.contains(reminder.intent.id) {
                try requireCurrent(); try await reminders?.erase(reminder.intent.id)
            }
            try requireCurrent(); try await reminders?.reconcileAll()
            let pending = try await inbox?.pending(now: clock()) ?? []
            try requireCurrent()
            if inbox != nil { try journal?.prune(pendingIDs: Set(pending.map(\.id)), now: clock()) }
            entries = pending; message = nil
            if let handle = pendingReminderTap {
                let resolved = try? await resolve(handle, reminderOnly: true)
                try requireCurrent()
                guard pendingReminderTap == handle else { return }
                pendingReminderTap = nil
                destination = resolved ?? .unavailable(UUID())
            }
            try publishWidget()
            if let pendingShortcut { self.pendingShortcut = nil; receive(pendingShortcut) }
            if let pendingHandle { self.pendingHandle = nil; Task { await open(pendingHandle) } }
        } catch { guard generation == start else { return }; entries = []; message = SurfaceCopy.text("Device shortcuts could not refresh. Try again.") }
    }
    func review(_ entry: SelectedTextEntry, shopID: UUID, replacing previous: SurfaceImportDraft? = nil) async {
        guard !busy, let bridge else { message = SurfaceCopy.text("Selected text is unavailable on this installation."); return }
        busy = true; defer { busy = false }
        let start = nonce
        do { let result = try await bridge.open(entry, shopID: shopID, replacing: previous); guard nonce == start else { return }; draft = result; reviewBaseline = result; await sourceDidChange() }
        catch SurfaceImportDestinationConflict.replaceReview(let saved) {
            guard nonce == start else { return }
            destinationChange = DestinationChange(entry: entry, shopID: shopID, previous: saved)
        }
        catch SurfaceImportDestinationConflict.recoverOriginalPickup {
            guard nonce == start else { return }
            message = SurfaceCopy.text("Choose the original pickup to finish the interrupted import.")
        }
        catch let limit as ImportTextLimit { message = ledgerImportLimitMessage(limit) }
        catch SurfaceError.capacity { message = SurfaceCopy.text("Share a smaller selection, or finish another selected-text review and try again.") }
        catch { message = SurfaceCopy.text("Review could not finish. Reopen this entry to check its saved result.") }
    }
    @discardableResult func saveDraft(_ updated: SurfaceImportDraft) -> Bool {
        guard let previous = draft, let bridge else { return false }
        do {
            try bridge.validateReview(updated, replacing: previous)
            draft = updated
            message = nil
            return true
        } catch {
            message = SurfaceCopy.text("This list changed. Reopen the saved list before reviewing again.")
            return false
        }
    }
    func saveReviewDraft() {
        guard !busy, let draft, let reviewBaseline, let bridge else { return }
        do {
            try bridge.saveReview(draft, replacing: reviewBaseline)
            self.reviewBaseline = draft
            message = SurfaceCopy.text("Review draft saved on this iPhone.")
        } catch { message = SurfaceCopy.text("This list changed. Reopen the saved list before reviewing again.") }
    }
    func chooseImportResolution(_ value: ImportResolution?, for id: UUID) {
        guard var next = draft, next.phase == .review, next.preview.lines.contains(where: { $0.id == id }),
              let shop = shop(next.preview.shopID) else { return }
        next.decisions[id] = value
        var explicit = next.explicitSeparate ?? []
        if value == .addNew { explicit.insert(id) } else { explicit.remove(id) }
        next.explicitSeparate = explicit
        next.decisions = LedgerImportReview(shop: shop, preview: next.preview, choices: next.decisions).choices
        saveDraft(next)
    }
    @discardableResult func editDraftLine(_ id: UUID, name: String, amount: String, unit: UnitOfMeasure) -> Bool {
        guard var next = draft, next.phase == .review, let index = next.preview.lines.firstIndex(where: { $0.id == id }), let shop = shop(next.preview.shopID) else { return false }
        do {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SurfaceError.invalid }
            next.preview.lines[index].name = name
            next.preview.lines[index].quantity = try LedgerEntry.quantity(amount, unit)
            next.preview.lines[index].unresolvedReason = next.preview.lines[index].quantity == nil ? "quantityUnknown" : nil
            let previous = next.preview
            next.preview = try shop.refreshImportMatches(previous)
            next.decisions = LedgerImportReview.afterEdit(from: previous, to: next.preview, shop: shop,
                choices: next.decisions, explicitSeparate: next.explicitSeparate ?? [])
            return saveDraft(next)
        } catch {
            message = SurfaceCopy.text("Review the item name, amount and matching lines before continuing.")
            return false
        }
    }
    func addReviewedList() async {
        guard !busy, let draft, let reviewBaseline, let bridge else { return }; busy = true; defer { busy = false }
        let start = nonce
        do {
            // An explicit Add confirms these edits. Persist before committing so
            // interruption/retry still recognizes the exact reviewed operation.
            if draft.phase == .review { try bridge.saveReview(draft, replacing: reviewBaseline) }
            try await bridge.commit(draft)
            guard nonce == start else { return }
            self.draft = nil; await sourceDidChange()
        } catch {
            // A completion from an earlier presentation must not restore private
            // review state cleared by background or an authority change.
            guard nonce == start else { return }
            self.draft = try? journal?.read(draft.id); self.reviewBaseline = self.draft
            message = SurfaceCopy.text("Review could not finish. Reopen this entry to check its saved result.")
        }
    }
    func cancelReview() { guard !busy else { return }; draft = nil }
    func recoverImport() async {
        guard privateAuthorized, !busy, let draft, let bridge else { return }
        busy = true; defer { busy = false }; let start = nonce
        do {
            let refreshed = try await bridge.refreshReview(draft.id)
            guard nonce == start else { return }; self.draft = refreshed; reviewBaseline = refreshed
            await sourceDidChange()
        } catch let limit as ImportTextLimit {
            message = ledgerImportLimitMessage(limit)
        } catch { message = SurfaceCopy.text("This list changed. Reopen the saved list before reviewing again.") }
    }
    func discard(_ entry: SelectedTextEntry) async {
        guard !busy, generation != nil, let inbox else { return }; busy = true; defer { busy = false }
        do {
            _ = try await inbox.discard(operationID: entry.id, digest: entry.receipt.digest, now: clock())
            if let saved = try journal?.read(entry.id) { try journal?.remove(saved.id, expected: saved) }
            await sourceDidChange()
        } catch { message = SurfaceCopy.text("Selected text could not be removed. Try again.") }
    }
    func handle(url: URL) {
        do {
            // Generic capture is also an own-request entry for a contributor.
            // Parsing its public scheme must not require private stores to open.
            if urls == nil { urls = try IOSSurfaceContainers.urls(bundle: bundle) }
            guard let urls else { throw SurfaceError.unconfigured }
            receive(try urls.parse(url).map(Shortcut.current) ?? .capture)
        } catch { destination = .unavailable(UUID()) }
    }
    private func receive(_ shortcut: Shortcut) {
        // URL and App Intent delivery may precede persona binding or scene activation.
        if ledger == nil || (hasAdultAuthority && (!active || authorityKey == nil || ledger?.ready != true || pickup?.ready != true)) {
            pendingShortcut = shortcut
            return
        }
        switch shortcut {
        case .capture:
            openCapture()
        case .current(let handle):
            guard privateAuthorized else { destination = .unavailable(UUID()); return }
            let start = nonce
            Task {
                guard nonce == start, privateAuthorized else { return }
                await open(handle)
            }
        }
    }
    private func openCapture() {
        ownRequestPersona = nil
        if privateAuthorized { destination = .capture(UUID()) }
        else if let persona = currentOwnRequestPersona {
            ownRequestPersona = persona; destination = .ownRequest(UUID())
        }
        else { destination = .unavailable(UUID()) }
    }
    func open(_ handle: RouteHandle) async {
        guard ledger != nil, ledger?.ready == true, pickup?.ready == true else { pendingHandle = handle; return }
        guard privateAuthorized else { destination = .unavailable(UUID()); return }
        await sourceDidChange()
        let start = nonce
        let resolved = try? await resolve(handle, reminderOnly: false)
        guard nonce == start else { return }
        destination = resolved ?? .unavailable(UUID())
    }
    private func resolve(_ handle: RouteHandle, reminderOnly: Bool) async throws -> SurfacePresentedDestination {
        guard let row = try routes?.all().first(where: { $0.route.handle == handle }),
              !reminderOnly || row.reminderID != nil, validTarget(row, requireRevision: row.reminderID != nil),
              let persona = access?.localActorID else { throw SurfaceError.unavailable }
        let auth = RouteAuthorization(personaID: persona, role: .localAdult, generation: routeGeneration(row.target), unlocked: true, permittedTargetIDs: [row.target.id])
        guard SurfaceRouter.resolve(row.route, handle: handle, authorization: auth, now: clock()) != nil else { throw SurfaceError.unavailable }
        if let reminderID = row.reminderID {
            guard let reminder = try await reminderStore?.get(reminderID), reminder.status != .cancelled,
                  !pendingReminderCancellation, reminderPersona == household?.deviceReminderPersona,
                  reminder.intent.personaID == persona, reminder.intent.routeHandle == handle,
                  reminder.intent.sourceRevision == row.sourceRevision,
                  validTarget(row, requireRevision: true) else { throw SurfaceError.unavailable }
            let cutoff: Date?
            if case .offer(_, let journey, let offerID) = row.target {
                guard reminder.intent.subject == .offer else { throw SurfaceError.unavailable }
                cutoff = pickup?.journeys.first(where: { $0.id == journey })?.offers.first(where: { $0.id == offerID })?.deadline.cutoff
            } else {
                guard case .deferral = row.target, reminder.intent.subject == .deferral else { throw SurfaceError.unavailable }
                cutoff = nil
            }
            guard ReminderOpening.evaluate(intent: reminder.intent, authorized: true, currentTargetID: row.target.id, currentCutoff: cutoff, now: clock()) != .unavailable else { throw SurfaceError.unavailable }
        }
        switch row.target {
        case .shop(_, let shop): return .shop(shop)
        case .offer(_, let journey, let offer): return .offer(journey, offer)
        case .deferral(_, let journey, let need): return .deferral(journey, need)
        }
    }
    private func routeGeneration(_ target: SurfacePrivateTarget) -> UUID {
        let workspace: UUID
        switch target { case .shop(let id, _), .offer(let id, _, _), .deferral(let id, _, _): workspace = id }
        let bytes = Array(SHA256.hash(data: Data(((access?.localActorID.uuidString ?? "") + workspace.uuidString).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func validTarget(_ row: SurfaceRouteRecord, requireRevision: Bool) -> Bool {
        guard privateAuthorized, row.route.personaID == access?.localActorID, row.route.generation == routeGeneration(row.target) else { return false }
        if row.reminderID != nil, !reminderRoleAuthorized { return false }
        let eligible = row.reminderID == nil ? pickup?.journeys : pickup?.reminderJourneys
        switch row.target {
        case .shop(let workspace, let shopID):
            // A widget opens the current pickup.
            return scope?.workspaceID == workspace && ledger?.shop?.id == shopID && shop(shopID) != nil
        case .offer(let workspace, let journeyID, let offerID):
            guard pickupWorkspaceID == workspace, let journey = eligible?.first(where: { $0.id == journeyID }),
                  journey.unfilledOffers(at: clock()).contains(where: { $0.id == offerID }) else { return false }
            return !requireRevision || journey.revision == row.sourceRevision
        case .deferral(let workspace, let journeyID, let needID):
            guard pickupWorkspaceID == workspace, let journey = eligible?.first(where: { $0.id == journeyID }), journey.deferred.contains(where: { $0.id == needID && $0.status == "review" }) else { return false }
            return !requireRevision || journey.revision == row.sourceRevision
        }
    }
    private func publishWidget() throws {
        guard let scope, let shop = ledger?.shop, let projection, let routes else { return }
        let target = SurfacePrivateTarget.shop(workspaceID: scope.workspaceID, shopID: shop.id)
        if let existing = try routes.all().first(where: { $0.target == target && $0.reminderID == nil && $0.route.personaID == scope.personaID }) {
            try projection.publishAfterCommit(WidgetProjection(generation: existing.route.generation, writtenAt: clock(), routeHandle: existing.route.handle, destination: .shoppingList))
        } else {
            let route = try PrivateRoute(handle: .random(), personaID: scope.personaID, targetID: shop.id, generation: routeGeneration(target), destination: .shoppingList, expiresAt: .distantFuture)
            try routes.put(SurfaceRouteRecord(route: route, target: target, sourceRevision: Int64(shop.revision), reminderID: nil))
            try projection.publishAfterCommit(WidgetProjection(generation: route.generation, writtenAt: clock(), routeHandle: route.handle, destination: .shoppingList))
        }
        runtime.performSystemEffect { WidgetCenter.shared.reloadTimelines(ofKind: "RoomInTheCartCapture") }
    }
    private func removeRoute(_ row: SurfaceRouteRecord) async throws {
        if let id = row.reminderID { try await reminders?.erase(id) }
        try routes?.remove(row.route.handle)
    }
    func eraseLedgerWorkspace(_ id: UUID) async throws {
        // Replayed by foreground tombstone reconciliation and Records deletion.
        try await CaptureMediaStore.shared.eraseWorkspace(id)
        try configure()
        if draft?.scope.workspaceID == id || destinationChange?.previous.scope.workspaceID == id {
            draft = nil
            destinationChange = nil
            nonce = UUID()
        }
        if case .shop(let shopID) = destination, ledger?.workspace.shops.contains(where: { $0.id == shopID }) != true { destination = nil }
        for review in try journal?.entries(workspaceID: id) ?? [] {
            guard let inbox else { throw SurfaceError.unconfigured }
            if let receipt = try await inbox.receipt(review.id), receipt.disposition == .pending {
                do { _ = try await inbox.discard(operationID: review.id, digest: review.inboxDigest, now: clock()) }
                catch {
                    // Expiry may remove the raw body during discard's transaction.
                    guard let final = try await inbox.receipt(review.id), final.digest == review.inboxDigest, final.disposition != .pending else { throw error }
                }
            }
        }
        try journal?.eraseWorkspace(id)
        for row in try routes?.all() ?? [] where row.target.belongsToLedger(id) { try await removeRoute(row) }
        try projection?.clear(now: clock()); runtime.performSystemEffect { WidgetCenter.shared.reloadTimelines(ofKind: "RoomInTheCartCapture") }
    }
    func erasePickupRecord(workspaceID: UUID, recordID: UUID) async throws {
        try await CaptureMediaStore.shared.erasePickupRecord(workspaceID: workspaceID, recordID: recordID)
        try configure()
        if case .offer(let journey, _) = destination, journey == recordID { destination = nil }
        if case .deferral(let journey, _) = destination, journey == recordID { destination = nil }
        for row in try routes?.all() ?? [] where row.target.belongsToPickup(workspaceID, recordID) { try await removeRoute(row) }
        try projection?.clear(now: clock()); runtime.performSystemEffect { WidgetCenter.shared.reloadTimelines(ofKind: "RoomInTheCartCapture") }
    }
    private var reminderRoleAuthorized: Bool {
        guard let role = household?.deviceReminderPersona.role else { return true }
        return ["shopper", "organizer"].contains(role)
    }
    var reminderEvaluationDate: Date { clock() }
    var reminderTargets: [SurfaceReminderTarget] {
        privateAuthorized && reminderRoleAuthorized ? currentReminderTargets : []
    }
    private var currentReminderTargets: [SurfaceReminderTarget] {
        guard let pickup, let workspace = pickupWorkspaceID, pickup.sourceWorkspaceID == workspace else { return [] }
        let projectionInstant = clock()
        return pickup.reminderJourneys.flatMap { journey in
            journey.unfilledOffers(at: projectionInstant).map { SurfaceReminderTarget(target: .offer(workspaceID: workspace, journeyID: journey.id, offerID: $0.id), title: $0.replacement, revision: journey.revision, cutoff: $0.deadline.cutoff, timeZoneID: $0.deadline.timeZoneID) }
            + journey.deferred.filter { $0.status == "review" }.map { SurfaceReminderTarget(target: .deferral(workspaceID: workspace, journeyID: journey.id, needID: $0.id), title: $0.line.name, revision: journey.revision, cutoff: nil, timeZoneID: TimeZone.current.identifier) }
        }
    }
    private func reminderRoute(for selected: SurfaceReminderTarget) throws -> SurfaceRouteRecord? {
        guard let routes else { throw SurfaceError.unavailable }
        return try routes.all().first {
            $0.reminderID != nil && $0.target == selected.target && $0.sourceRevision == selected.revision &&
                $0.route.personaID == access?.localActorID && $0.route.generation == routeGeneration(selected.target)
        }
    }

    /// Populate the expiry picker without creating a route or registering a notification.
    func initialReminderExpiry(_ selected: SurfaceReminderTarget) async throws -> Date {
        guard let authorization = reminderAuthorization(selected), let reminderStore else { throw SurfaceError.stale }
        if let cutoff = selected.cutoff { return cutoff }
        if let id = try reminderRoute(for: selected)?.reminderID {
            let saved = try await reminderStore.get(id)
            guard reminderAuthorization(selected) == authorization else { throw SurfaceError.stale }
            if let saved { return saved.intent.expiresAt }
        }
        return clock().addingTimeInterval(86_400)
    }

    func reminderContext(_ selected: SurfaceReminderTarget, expiresAt: Date) async throws -> ReminderEditorContext {
        guard let authorization = reminderAuthorization(selected), let persona = access?.localActorID,
              let routes, let reminderStore else { throw SurfaceError.stale }
        let previous = try reminderRoute(for: selected)
        let handle = previous?.route.handle ?? .random(), reminderID = previous?.reminderID ?? UUID()
        if previous == nil {
            let route = try PrivateRoute(handle: handle, personaID: persona, targetID: selected.id, generation: routeGeneration(selected.target), destination: .shoppingList, expiresAt: .distantFuture)
            try routes.put(SurfaceRouteRecord(route: route, target: selected.target, sourceRevision: selected.revision, reminderID: reminderID))
        }
        let saved = try await reminderStore.get(reminderID)
        guard reminderAuthorization(selected) == authorization else { throw SurfaceError.stale }
        let quietHours = saved == nil ? try QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : saved?.intent.quietHours
        return ReminderEditorContext(reminderID: reminderID, personaID: persona, targetID: selected.id, subject: selected.cutoff == nil ? .deferral : .offer, sourceRevision: selected.revision,
            routeHandle: handle, expiresAt: selected.cutoff ?? expiresAt, cutoff: selected.cutoff, initialFireAt: saved?.intent.fireAt ?? clock().addingTimeInterval(3600),
            timeZoneID: saved?.intent.localTime.timeZoneID ?? selected.timeZoneID, initialQuietHours: quietHours, expectedVersion: saved?.version)
    }
    func reminderAuthorization(_ selected: SurfaceReminderTarget) -> UUID? { privateAuthorized && reminderTargets.contains(selected) ? nonce : nil }
    func authorizeReminderSave(_ selected: SurfaceReminderTarget, reviewedGeneration: UUID) -> ReminderCoordinator.SaveAuthorization? {
        guard reminderAuthorization(selected) == reviewedGeneration, !pendingReminderCancellation,
              let persona = household?.deviceReminderPersona, reminderPersona == persona else { return nil }
        let generation = reminderSaveGeneration
        return { @MainActor [weak self] in
            guard let self else { return false }
            return self.reminderSaveGeneration == generation && !self.pendingReminderCancellation &&
                self.household?.deviceReminderPersona == persona && self.currentReminderTargets.contains {
                    $0.target == selected.target && $0.revision == selected.revision
                }
        }
    }
}

struct SurfaceReminderTarget: Identifiable, Equatable, Sendable {
    var id: UUID { target.id }
    let target: SurfacePrivateTarget
    let title: String
    let revision: Int64
    let cutoff: Date?
    let timeZoneID: String
}
enum SurfacePresentedDestination: Identifiable {
    case capture(UUID), ownRequest(UUID), shop(UUID), offer(UUID, UUID), deferral(UUID, UUID), unavailable(UUID)
    var id: UUID { switch self { case .capture(let id), .ownRequest(let id), .shop(let id), .unavailable(let id): return id; case .offer(_, let id), .deferral(_, let id): return id } }
}
