import SwiftUI
import Foundation
import CoreDomain
import LocalStore
import RecordArchive
import HouseholdClient

/// The records boundary owns explicit domain projections. Databases, credentials,
/// consent, membership and grants are never archive payloads.
private struct RecordsLedgerDocument: Codable {
    let formatVersion: Int
    let workspace: LedgerWorkspace
}

/// Persisted planning evidence only. Runtime DinnerAccessContext is deliberately
/// absent; restoring these facts cannot restore membership, budget access or seats.
private struct RecordsPlanningProjection: Codable {
    let revisionID: UUID
    let acceptedDinners: [AcceptedDinner]
    let freeReusableDinnerID: UUID?
    let rotations: [DinnerRotation]
    let portionBindings: [DinnerPortionBinding]
    let protectedDays: [DinnerProtectedDay]
    let weekNotes: [DinnerWeekNote]
    let ideas: [DinnerIdeaDraft]
    let proposals: [DinnerProposal]
    let applyReceipts: [DinnerApplyReceipt]
    let quotePairs: [TwoStoreQuotePair]
    init(_ state: DinnerPlanningState, shop: ShoppingLedger?) {
        revisionID = state.revisionID
        if let shop {
            proposals = state.proposals.filter { $0.shopID == shop.id }
            applyReceipts = state.applyReceipts.filter { $0.proposal.shopID == shop.id }
            let referenced = Set((proposals + applyReceipts.map(\.proposal)).flatMap { proposal in
                proposal.changes.compactMap { change -> UUID? in
                    if case .choose(let chosen) = change { return chosen.acceptedDinnerID }; return nil
                }
            })
            let accepted = state.acceptedDinners.filter { dinner in
                referenced.contains(dinner.id) || shop.mealOccurrences.contains {
                    $0.templateID == dinner.template.id && $0.templateRevision == dinner.template.revision
                }
            }
            acceptedDinners = accepted
            freeReusableDinnerID = state.freeReusableDinnerID.flatMap { id in accepted.contains(where: { $0.id == id }) ? id : nil }
            rotations = []
            let occurrenceIDs = Set(shop.mealOccurrences.map(\.id))
            portionBindings = state.portionBindings.filter { occurrenceIDs.contains($0.occurrenceID) }
            protectedDays = state.protectedDays.filter { $0.shopID == shop.id }
            weekNotes = state.weekNotes.filter { $0.shopID == shop.id }
            let ideaIDs = Set(acceptedDinners.compactMap(\.sourceIdeaID))
            ideas = state.ideas.filter { ideaIDs.contains($0.id) }
            quotePairs = state.quotePairs.filter { $0.shopID == shop.id }
        } else {
            acceptedDinners = state.acceptedDinners; freeReusableDinnerID = state.freeReusableDinnerID
            rotations = state.rotations; ideas = state.ideas
            portionBindings = []; protectedDays = []; weekNotes = []; proposals = []; applyReceipts = []; quotePairs = []
        }
    }
    func decoded() throws -> DinnerPlanningState {
        try JSONDecoder().decode(DinnerPlanningState.self, from: ArchiveCodec.canonical(self))
    }
}

@MainActor enum RecordsNativeCodec {
    /// These domain fields encode sets or UUID-keyed dictionaries as JSON arrays.
    /// Sort only those schema-defined unordered collections; preserve recipe/list order.
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: ArchiveCodec.canonical(value))
        func normalize(_ value: Any, key: String? = nil) throws -> Any {
            if let object = value as? [String: Any] {
                return try object.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = try normalize(pair.value, key: pair.key)
                }
            }
            if let array = value as? [Any] {
                if let key, ["flexible", "undoneProposals"].contains(key), let strings = array as? [String] { return strings.sorted() }
                if let key, ["frozenQuotes", "decisions"].contains(key) {
                    guard array.count.isMultiple(of: 2) else { throw ArchiveError.unsupportedRecord }
                    var pairs: [(String, Any)] = []
                    for index in stride(from: 0, to: array.count, by: 2) {
                        guard let id = array[index] as? String else { throw ArchiveError.unsupportedRecord }
                        pairs.append((id, try normalize(array[index + 1])))
                    }
                    return pairs.sorted { $0.0 < $1.0 }.flatMap { [$0.0 as Any, $0.1] }
                }
                return try array.map { try normalize($0) }
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: normalize(object), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func comparison(_ data: Data) throws -> SavedPayload {
        try ArchiveCodec.preflight(data)
        let payload = try JSONDecoder().decode(SavedPayload.self, from: data)
        guard payload.formatVersion == 1 else { throw ArchiveError.unsupportedVersion }
        let request = try ComparisonModel(draft: payload.draft).request()
        let computed = try PackComparison.evaluate(request)
        if let version = payload.calculationVersion {
            guard version == SavedPayload.currentCalculationVersion,
                  payload.roundingPolicy == SavedPayload.currentRoundingPolicy,
                  payload.normalizedRequest == request, payload.answer == computed else { throw ArchiveError.unsupportedRecord }
        } else {
            guard payload.normalizedRequest == nil, payload.answer == nil, payload.roundingPolicy == nil else { throw ArchiveError.unsupportedRecord }
        }
        return payload
    }
    static func ledger(_ data: Data) throws -> LedgerWorkspace {
        try ArchiveCodec.preflight(data)
        return try LedgerModel.validatePayload(data)
    }
    static func ledgerScope(_ workspace: LedgerWorkspace, shop: ShoppingLedger) throws -> LedgerWorkspace {
        let planning = try RecordsPlanningProjection(workspace.dinnerPlanning, shop: shop).decoded()
        var value = LedgerWorkspace(shops: [shop], mealTemplates: [], selectedShopID: shop.id, dinnerPlanning: planning,
            packSelections: workspace.packSelections.filter { $0.shopID == shop.id })
        let shopKey = shop.id.uuidString.lowercased()
        let visibleAisles = Set(shop.lines.map { $0.aisle.trimmingCharacters(in: .whitespacesAndNewlines) })
        if var local = workspace.listLayout.shopLayouts[shopKey] {
            local.aisleOverride = local.aisleOverride?.filter(visibleAisles.contains)
            value.listLayout.shopLayouts[shopKey] = local
        }
        let branch = shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if let order = workspace.listLayout.storeAisles[branch]?.filter(visibleAisles.contains), !order.isEmpty {
            value.listLayout.storeAisles[branch] = order
        }
        try value.validate()
        return value
    }
    static func ledgerLibrary(_ workspace: LedgerWorkspace) throws -> LedgerWorkspace? {
        let planning = try RecordsPlanningProjection(workspace.dinnerPlanning, shop: nil).decoded()
        guard !workspace.mealTemplates.isEmpty || !planning.acceptedDinners.isEmpty || !planning.rotations.isEmpty || !planning.ideas.isEmpty else { return nil }
        let value = LedgerWorkspace(mealTemplates: workspace.mealTemplates, dinnerPlanning: planning)
        try value.validate()
        return value
    }
    private static func canonicalLedgerForImport(_ workspace: LedgerWorkspace, original: Data) throws -> Data {
        let normalized = try canonical(RecordsLedgerDocument(formatVersion: 1, workspace: workspace))
        // These public v1 fields have documented empty defaults. Only absent known
        // additions are normalized; unknown fields still fail equality.
        guard let source = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              let oldWorkspace = source["workspace"] as? [String: Any] else { return normalized }
        var object = try JSONSerialization.jsonObject(with: normalized) as! [String: Any]
        var body = object["workspace"] as! [String: Any]
        for key in ["dinnerPlanning", "packSelections"] where oldWorkspace[key] == nil { body.removeValue(forKey: key) }
        object["workspace"] = body
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func pickup(_ data: Data) throws -> PickupJourney {
        try ArchiveCodec.preflight(data)
        let value = try JSONDecoder().decode(PickupJourney.self, from: data)
        try PickupModel.validate(value)
        return value
    }
    private static func canonicalPickupForImport(_ value: PickupJourney, original: Data) throws -> Data {
        let normalized = try canonical(value)
        guard let source = try JSONSerialization.jsonObject(with: original) as? [String: Any], source["ledgerPackSelections"] == nil else { return normalized }
        var object = try JSONSerialization.jsonObject(with: normalized) as! [String: Any]
        object.removeValue(forKey: "ledgerPackSelections")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    /// Re-export an edited independent workspace with only the historical source
    /// references still owned by this emitted shop/library. The original registry
    /// snapshot keeps its own historical evidence unchanged.
    static func revised(_ original: ArchiveRecord, nativePayload bytes: Data, id: String, title: String,
                        date: Date, lines: [HelperLine]) throws -> ArchiveRecord {
        var record = original
        record.id = id; record.title = title; record.helperLines = lines; record.nativePayload = bytes
        let unchanged = bytes == original.nativePayload && id == original.id
        record.revision = unchanged ? original.revision : ArchiveCodec.digest(bytes)
        record.parentRevision = unchanged ? original.parentRevision : original.revision
        record.savedAtMilliseconds = unchanged ? original.savedAtMilliseconds : ArchiveCodec.milliseconds(date)
        let ownedMedia = try (original.media ?? []).filter {
            try RecordsMediaCodec.belongs(RecordsMediaCodec.decode($0), to: record, captureNamespace: $0.captureNamespace)
        }
        record.media = ownedMedia.isEmpty ? nil : ownedMedia
        return record
    }
    static func recoveredLedger(_ saved: RecoveredRecord, current: LedgerRecord, scope: RecordsRecoveryCapture.Scope,
                                sources: [SourceMediaRecord]) throws -> [ArchiveRecord] {
        let workspace = try ledger(current.payload)
        var result = try workspace.shops.map { shop in
            let scoped = try ledgerScope(workspace, shop: shop)
            let bytes = try canonical(RecordsLedgerDocument(formatVersion: 1, workspace: scoped))
            let lines = shop.contributions.filter { $0.removedAt == nil }.map {
                HelperLine(label: $0.productName, originalAmount: $0.quantity?.originalLiteral ?? "", originalUnit: $0.quantity?.unit.rawValue ?? "")
            }
            return try revised(saved.record, nativePayload: bytes, id: shop.id.uuidString, title: shop.title, date: current.savedAt, lines: lines)
        }
        if let library = try ledgerLibrary(workspace) {
            let bytes = try canonical(RecordsLedgerDocument(formatVersion: 1, workspace: library))
            result.append(try revised(saved.record, nativePayload: bytes, id: "meal-library", title: "Reusable dinners", date: current.savedAt, lines: []))
        }
        return try result.map { try RecordsMediaCodec.attaching(sources, to: $0, liveScope: scope) }
    }
    static func validate(_ record: ArchiveRecord) throws {
        try RecordsMediaCodec.validate(record)
        guard let bytes = record.nativePayload else { return }
        let normalized: Data
        switch record.kind {
        case .comparison:
            let value = try comparison(bytes)
            guard value.draft.id.uuidString == record.id, value.draft.item == record.title else { throw ArchiveError.invalidIdentity }
            normalized = try canonical(value)
        case .ledger:
            let workspace = try ledger(bytes)
            guard (workspace.shops.count == 1 && workspace.shops[0].id.uuidString == record.id) || (workspace.shops.isEmpty && record.id == "meal-library") else { throw ArchiveError.invalidIdentity }
            normalized = try canonicalLedgerForImport(workspace, original: bytes)
        case .pickup:
            let value = try pickup(bytes)
            guard value.id.uuidString == record.id else { throw ArchiveError.invalidIdentity }
            normalized = try canonicalPickupForImport(value, original: bytes)
        case .sharedShop:
            normalized = try SharedRecordArchiveAdapter.validate(record).independentData()
        case .sharedHistory:
            normalized = try SharedHistoryArchiveAdapter.validate(record).independentData()
        case .recipe:
            let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: bytes).validated()
            normalized = try ArchiveCodec.canonical(recipe)
        }
        // Re-encoding the typed domain allowlist rejects extra keys at every depth.
        guard bytes == normalized else { throw ArchiveError.unsupportedRecord }
    }
}

/// Root must supply the actual cleanup for every app-private projection store.
/// A failed cleanup remains retryable through the durable source tombstones.
struct RecordsErasureCleanup {
    let eraseLedgerWorkspace: @MainActor (UUID) async throws -> Void
    let erasePickupRecord: @MainActor (UUID, UUID) async throws -> Void
}

@MainActor enum RecordsLedgerErasure {
    static func reconcile(ledger: LedgerModel, registry: RecoveryRegistry, cleanup: RecordsErasureCleanup,
                          purgeRecovered: () async throws -> Void) async throws {
        let retiredIDs = try await ledger.retiredLedgerWorkspaceIDs()
        try await registry.registerErasedOrigins(retiredIDs.map { "ledger/" + $0.uuidString })
        for id in retiredIDs { try await cleanup.eraseLedgerWorkspace(id) }
        try await purgeRecovered()
    }

    static func complete(_ review: WholeLedgerDeletionReview, ledger: LedgerModel, registry: RecoveryRegistry,
                         cleanup: RecordsErasureCleanup, purgeRecovered: () async throws -> Void) async throws {
        _ = try await ledger.eraseWholeLedger(review)
        try await reconcile(ledger: ledger, registry: registry, cleanup: cleanup, purgeRecovered: purgeRecovered)
        try await ledger.finishWholeLedgerDeletion()
    }
}

struct RecordsToolsEntryView: View {
    @StateObject private var composition: RecordsComposition
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    init(app: AppModel, ledger: LedgerModel, pickup: PickupModel, erasureCleanup: RecordsErasureCleanup) {
        _composition = StateObject(wrappedValue: RecordsComposition(app: app, ledger: ledger, pickup: pickup, erasureCleanup: erasureCleanup))
    }
    var body: some View {
        Group {
            if let tools = composition.tools { RecordsToolsView(model: tools) }
            else if composition.error != nil {
                ContentUnavailableView {
                    Label(recordsText("Records could not open"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(recordsText("Your saved work is unchanged. Try opening records again."))
                } actions: {
                    Button(recordsText("Try again")) { Task { await composition.load() } }
                }
            } else { ProgressView(recordsText("Opening records…")) }
        }
        .task {
            composition.bind(access: access, household: household, active: scenePhase == .active)
            await composition.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                composition.checkAccess()
            }
        }
        .onChange(of: scenePhase) { _, phase in composition.bind(access: access, household: household, active: phase == .active) }
        .onDisappear { composition.clearPrivatePreviews() }
        .sheet(item: $composition.destination, onDismiss: { Task { await composition.tools?.refresh() } }) { destination in
            NavigationStack {
                Group {
                    switch destination.content {
                    case let .comparison(app, draft, date): ComparisonView(draft: draft, savedAt: date).environmentObject(app)
                    case let .ledger(model):
                        List {
                            Text(recordsText("This is a separate recovered workspace. Your current pickup is unchanged."))
                            NavigationLink(recordsText("Open recovered shopping list")) { LedgerHomeView(model: model) }
                            NavigationLink(recordsText("Open recovered dinners")) { RecordsRecoveredDinnersView(ledger: model) }
                        }.navigationTitle(recordsText("Recovered workspace")).environmentObject(model)
                    case let .pickup(model): PickupHomeView(model: model).environment(\.pickupLedger, nil)
                    case let .recipe(recipe): RecordsRecipeAdoptionView(recipe: recipe, ledger: composition.ledger)
                    case let .sharedRecord(record, text):
                        ScrollView { Text(text).textSelection(.enabled).accessibilityIdentifier("records.sharedRecoveredText").frame(maxWidth: .infinity, alignment: .leading).padding() }
                            .navigationTitle(recordsTitle(record))
                    case let .ledgerDeletion(review):
                        RecordsLedgerDeletionView(ledger: composition.ledger, review: review) {
                            try await composition.deleteWholeLedger(review)
                        }
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(recordsText("Done")) { composition.destination = nil }.disabled(composition.deletingLedger) } }
            }
        }
    }
}

private struct RecordsRecoveredDinnersView: View {
    @ObservedObject var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    var body: some View {
        Group {
            if ledger.shop == nil {
                List {
                    Text(recordsText("Start a shopping list in this separate recovered workspace to review and choose from its dinner library."))
                    NavigationLink(recordsText("Open recovered shopping list")) { LedgerHomeView(model: ledger) }
                }
            } else {
                DinnerPlanningHome(ledger: ledger, access: { shopID in
                    guard access.unlocked, ledger.ready, let workspaceID = ledger.sourceWorkspaceID,
                          ledger.workspace.shops.contains(where: { $0.id == shopID }) else { return nil }
                    let now = Date(), actor = access.localActorID.uuidString
                    return DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: actor,
                        shopID: shopID, assignedShopperID: actor, canPlan: true, canReadBudget: true,
                        hasPaidTools: false, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30),
                        sharedCommitAuthorized: false)
                }, phase: { _ in .draft })
            }
        }.navigationTitle(recordsText("Recovered workspace"))
    }
}

@MainActor private final class RecordsComposition: ObservableObject {
    struct Destination: Identifiable {
        enum Content { case comparison(AppModel, ComparisonDraft, Date), ledger(LedgerModel), pickup(PickupModel), recipe(ImportedRecipe), sharedRecord(ArchiveRecord, String), ledgerDeletion(WholeLedgerDeletionReview) }
        let id: String
        let content: Content
    }
    @Published var tools: RecordsToolsModel?
    @Published var destination: Destination?
    @Published var error: ArchiveError?
    @Published private(set) var deletingLedger = false
    let app: AppModel
    let ledger: LedgerModel
    let pickup: PickupModel
    private let erasureCleanup: RecordsErasureCleanup
    private var registry: RecoveryRegistry?
    private var directory: URL?
    private var loading = false
    private var pickupOrigin: String?
    private var unavailableRecords: [RecordsUnavailableRecord] = []
    private weak var access: WorkspaceAccess?
    private weak var household: HouseholdModel?
    private var active = false
    private var visibleIdentity: CapturePrivateIdentity?
    private var authorizationGeneration = UUID()
    private let recoveryLifetime = RecordsRecoveryLifetime.shared
    func bind(access: WorkspaceAccess, household: HouseholdModel, active: Bool) {
        self.access = access; self.household = household; self.active = active
        checkAccess()
    }
    func checkAccess() {
        let identity = active ? privateIdentity() : nil
        if identity != visibleIdentity { clearPrivatePreviews(); visibleIdentity = identity }
    }
    func clearPrivatePreviews() { authorizationGeneration = UUID(); recoveryLifetime.invalidate(); tools?.invalidateForSourceErasure(); destination = nil }
    private func privateIdentity() -> CapturePrivateIdentity? {
        guard let access, let household else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private func captureAuthorization() -> RecordsToolsModel.Authorization? {
        guard active, let identity = privateIdentity() else { return nil }
        let ledgerID = ledger.sourceWorkspaceID, comparisonID = app.store?.workspaceID
        let generation = authorizationGeneration
        return { [weak self] in
            guard let self else { return false }
            return self.active && self.authorizationGeneration == generation && self.privateIdentity() == identity &&
                self.ledger.sourceWorkspaceID == ledgerID && self.app.store?.workspaceID == comparisonID
        }
    }
    init(app: AppModel, ledger: LedgerModel, pickup: PickupModel, erasureCleanup: RecordsErasureCleanup) {
        self.app = app; self.ledger = ledger; self.pickup = pickup; self.erasureCleanup = erasureCleanup
    }
    func load() async {
        guard tools == nil, !loading else { return }
        loading = true; defer { loading = false }
        do {
            await app.open(); await ledger.open(); await pickup.load()
            guard (app.ready && ledger.ready) || ledger.hasPendingLedgerDeletion else { throw ArchiveError.unavailable }
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var folder = base.appendingPathComponent("RoomInTheCart", isDirectory: true)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { folder = base.appendingPathComponent("UITestWorkspace", isDirectory: true) }
            #endif
            let directory = folder.appendingPathComponent("Records", isDirectory: true)
            try protectDirectory(directory)
            self.directory = directory
            let registry = try RecoveryRegistry(url: directory.appendingPathComponent("recovery-v1.json"))
            self.registry = registry
            if ledger.hasPendingLedgerDeletion { try await synchronizeLedgerErasure() }
            else { try await synchronizeErasure() }
            if !ledger.hasPendingLedgerDeletion { pickupOrigin = "pickups/" + (try await pickup.archiveListing()).workspaceID.uuidString }
            tools = RecordsToolsModel(registry: registry, snapshot: { [weak self] in
                guard let self else { throw ArchiveError.unavailable }; return try await self.snapshot()
            }, validateNativePayload: { [weak self] record in
                guard let self else { throw ArchiveError.unavailable }; try await self.validate(record)
            }, openRecovered: { [weak self] record in
                guard let self else { throw ArchiveError.unavailable }; try await self.open(record)
            }, deleteSource: { [weak self] record in
                guard let self else { throw ArchiveError.unavailable }; try await self.delete(record)
            }, canDeleteSource: { [weak self] record in
                guard let self else { return false }
                return (record.kind == .comparison && record.origin == self.app.store.map { "comparisons/" + $0.workspaceID.uuidString }) || (record.kind == .pickup && record.origin == self.pickupOrigin)
            }, cleanupRecoveredWorkspaces: { [weak self] in
                guard let self else { throw ArchiveError.unavailable }; try await self.purgeOrphanWorkspaces()
            }, willRemoveRecovered: { [weak self] in
                self?.recoveryLifetime.invalidate(); self?.destination = nil
            }, reviewWholeLedgerDeletion: { [weak self] in
                guard let self else { throw ArchiveError.unavailable }
                let review = try await self.ledger.reviewWholeLedgerDeletion()
                self.destination = Destination(id: "whole-ledger-deletion", content: .ledgerDeletion(review))
            }, unavailableRecords: { [weak self] in self?.unavailableRecords ?? [] }, beginAuthorization: { [weak self] in self?.captureAuthorization() })
            error = nil
        } catch { self.error = error as? ArchiveError ?? .unavailable }
    }
    private func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var directory = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    private func synchronizeErasure() async throws {
        guard let registry, let store = app.store else { throw ArchiveError.unavailable }
        let tombstones = try await store.tombstones()
        let pickupTombstones = try await pickup.archiveTombstones()
        let erased = tombstones.map { ArchiveSourceIdentity(origin: "comparisons/" + $0.workspaceID.uuidString, recordID: $0.id.uuidString) }
            + pickupTombstones.map { ArchiveSourceIdentity(origin: "pickups/" + $0.workspaceID.uuidString, recordID: $0.id.uuidString) }
        try await registry.registerErasedSources(erased)
        for tombstone in pickupTombstones { try await erasureCleanup.erasePickupRecord(tombstone.workspaceID, tombstone.id) }
        try await synchronizeLedgerErasure()
        var erasedMedia: [ArchiveMediaSourceIdentity] = []
        for saved in try await registry.refreshList() {
            for attachment in saved.record.media ?? [] {
                let source = try RecordsMediaCodec.decode(attachment)
                if try await CaptureMediaStore.shared.isRetired(source) {
                    erasedMedia.append(ArchiveMediaSourceIdentity(origin: saved.record.origin, mediaID: attachment.id))
                }
            }
        }
        try await registry.registerErasedMedia(erasedMedia)
    }
    private func synchronizeLedgerErasure() async throws {
        guard let registry else { throw ArchiveError.unavailable }
        try await RecordsLedgerErasure.reconcile(ledger: ledger, registry: registry, cleanup: erasureCleanup) {
            try await self.purgeOrphanWorkspaces()
        }
    }
    private func purgeOrphanWorkspaces() async throws {
        guard let registry, let directory else { throw ArchiveError.unavailable }
        let root = directory.appendingPathComponent("Recoveries", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let retained = Set(try await registry.refreshList().map(\.id))
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && !retained.contains($0.lastPathComponent) }
        guard !folders.isEmpty else { return }
        recoveryLifetime.invalidate(); destination = nil
        await recoveryLifetime.drain()
        // A concurrent reviewed import may have retained a copy while we drained.
        let current = Set(try await registry.refreshList().map(\.id))
        let protectedWorkspaceIDs = Set([ledger.sourceWorkspaceID, pickup.sourceWorkspaceID, app.store?.workspaceID].compactMap { $0 })
        for url in folders {
            guard !current.contains(url.lastPathComponent) else { continue }
            try await RecordsRecoveryCapture.erase(directory: url, protectedWorkspaceIDs: protectedWorkspaceIDs)
            try FileManager.default.removeItem(at: url)
        }
    }
    private func snapshot() async throws -> [ArchiveRecord] {
        guard let authorize = captureAuthorization(), authorize() else { throw ArchiveError.unavailable }
        try await synchronizeErasure()
        guard authorize() else { throw ArchiveError.unavailable }
        guard let store = app.store else { throw ArchiveError.unavailable }
        var result: [ArchiveRecord] = []
        unavailableRecords = []
        // Refresh current permissions and privacy before every listing/export.
        // No previous shared snapshot is used as an offline authorization fallback.
        if let household, let scope = household.projection, scope.capabilities.contains("shopper_commands"),
           let shop = scope.shopId, let shopID = UUID(uuidString: shop), let service = household.service {
            do {
                let shared = try await service.sharedRecordSnapshot(shopID: shopID)
                guard authorize() else { throw ArchiveError.unavailable }
                result.append(try SharedRecordArchiveAdapter.make(shared))
            } catch {
                guard authorize() else { throw ArchiveError.unavailable }
                unavailableRecords.append(RecordsUnavailableRecord(origin: "shared-shop/" + scope.household.id,
                    recordID: shopID.uuidString.lowercased(), title: nil, reason: .unreadableStorage))
            }
            do {
                let history = try await service.sharedRecordHistory(shopID: shopID)
                guard authorize() else { throw ArchiveError.unavailable }
                result.append(try SharedHistoryArchiveAdapter.make(history))
            } catch {
                guard authorize() else { throw ArchiveError.unavailable }
                unavailableRecords.append(RecordsUnavailableRecord(origin: "shared-history/" + scope.household.id,
                    recordID: shopID.uuidString.lowercased() + "/history", title: recordsText("Shared pickup history"), reason: .unreadableStorage))
            }
        }
        let comparisonOrigin = "comparisons/" + store.workspaceID.uuidString
        let comparisonBatch = RecordsSnapshotProjection.project(try await store.listing(), origin: comparisonOrigin) { saved in
            let payload = try RecordsNativeCodec.comparison(saved.payload)
            guard payload.draft.id == saved.id else { throw ArchiveError.invalidIdentity }
            let bytes = try RecordsNativeCodec.canonical(payload)
            let draft = payload.draft
            return ArchiveRecord(id: saved.id.uuidString, origin: "comparisons/" + store.workspaceID.uuidString,
                revision: ArchiveCodec.digest(bytes), kind: .comparison, title: draft.item,
                savedAtMilliseconds: ArchiveCodec.milliseconds(saved.savedAt),
                helperLines: [HelperLine(label: draft.item, originalAmount: draft.needed, originalUnit: draft.unit.rawValue)], nativePayload: bytes)
        }
        result += comparisonBatch.records; unavailableRecords += comparisonBatch.unavailable
        if ledger.ready, let originID = ledger.sourceWorkspaceID {
            let workspace = try RecordsNativeCodec.ledger(ledger.exportPayload())
            for shop in workspace.shops {
                let scoped = try RecordsNativeCodec.ledgerScope(workspace, shop: shop)
                let bytes = try RecordsNativeCodec.canonical(RecordsLedgerDocument(formatVersion: 1, workspace: scoped))
                let lines = shop.contributions.filter { $0.removedAt == nil }.map { contribution in
                    HelperLine(label: contribution.productName, originalAmount: contribution.quantity?.originalLiteral ?? "",
                               originalUnit: contribution.quantity?.unit.rawValue ?? "")
                }
                result.append(ArchiveRecord(id: shop.id.uuidString, origin: "ledger/" + originID.uuidString,
                    revision: ArchiveCodec.digest(bytes), kind: .ledger, title: shop.title,
                    savedAtMilliseconds: ArchiveCodec.milliseconds(ledger.savedAt ?? Date(timeIntervalSince1970: 0)), helperLines: lines, nativePayload: bytes))
            }
            if let library = try RecordsNativeCodec.ledgerLibrary(workspace) {
                let bytes = try RecordsNativeCodec.canonical(RecordsLedgerDocument(formatVersion: 1, workspace: library))
                result.append(ArchiveRecord(id: "meal-library", origin: "ledger/" + originID.uuidString,
                    revision: ArchiveCodec.digest(bytes), kind: .ledger, title: "Reusable dinners",
                    savedAtMilliseconds: ArchiveCodec.milliseconds(ledger.savedAt ?? Date(timeIntervalSince1970: 0)), nativePayload: bytes))
            }
        }
        let pickupSnapshot = try await pickup.archiveListing()
        let pickupBatch = RecordsSnapshotProjection.project(pickupSnapshot.listing, origin: "pickups/" + pickupSnapshot.workspaceID.uuidString) { saved in
            let value = try RecordsNativeCodec.pickup(saved.payload)
            guard value.id == saved.id else { throw ArchiveError.invalidIdentity }
            let bytes = try RecordsNativeCodec.canonical(value)
            let lines = (value.basket?.current.lines ?? []).map { line in
                HelperLine(label: line.name, originalAmount: line.quantity.originalLiteral, originalUnit: line.quantity.unit.rawValue)
            }
            return ArchiveRecord(id: saved.id.uuidString, origin: "pickups/" + pickupSnapshot.workspaceID.uuidString,
                revision: ArchiveCodec.digest(bytes), kind: .pickup,
                title: value.basket?.current.lines.first?.name ?? value.urgent.first?.meal ?? "Pickup",
                savedAtMilliseconds: ArchiveCodec.milliseconds(saved.savedAt), helperLines: lines, nativePayload: bytes)
        }
        result += pickupBatch.records; unavailableRecords += pickupBatch.unavailable
        // A separately recovered workspace may have been edited since import. Export
        // its committed domain state, retaining the original source identity and parent.
        if let registry {
            let pendingOrigin = ledger.pendingLedgerDeletionReview.map { "ledger/" + $0.workspaceID.uuidString }
            for saved in try await registry.refreshList() where saved.record.origin != pendingOrigin {
                do { result += try await recoveredSnapshot(saved, authorize: authorize) }
                catch {
                    guard authorize() else { throw ArchiveError.unavailable }
                    _ = omitRecovered(saved, reason: .unreadableStorage)
                }
            }
        }
        guard authorize() else { throw ArchiveError.unavailable }
        // Never scan a namespace supplied by a recovered file. Only live app stores
        // provide namespace authority; typed owner binding filters each attachment.
        var sourceMedia: [SourceMediaRecord] = []
        if ledger.ready, !ledger.hasPendingLedgerDeletion, let id = ledger.sourceWorkspaceID {
            let listing = try await mediaListing(workspaceID: id, authorize: authorize)
            sourceMedia += listing.records
        }
        guard authorize() else { throw ArchiveError.unavailable }
        sourceMedia += try await mediaListing(workspaceID: pickupSnapshot.workspaceID, authorize: authorize).records
        guard authorize() else { throw ArchiveError.unavailable }
        for index in result.indices {
            result[index] = try RecordsMediaCodec.attaching(sourceMedia, to: result[index])
        }
        var merged: [ArchiveRecord] = [], indices: [String: Int] = [:]
        for record in result {
            let key = RecordsToolsModel.selectionID(record)
            guard let index = indices[key] else { indices[key] = merged.count; merged.append(record); continue }
            var attachments = merged[index].media ?? []
            for attachment in record.media ?? [] {
                if let existing = attachments.first(where: { $0.id == attachment.id }) {
                    guard existing == attachment else { throw ArchiveError.conflict }
                } else { attachments.append(attachment) }
            }
            merged[index].media = attachments.isEmpty ? nil : attachments.sorted { $0.id < $1.id }
        }
        return merged
    }
    private func mediaListing(workspaceID: UUID, authorize: @escaping RecordsToolsModel.Authorization, liveScope: RecordsRecoveryCapture.Scope? = nil) async throws -> CaptureMediaArchiveListing {
        if let liveScope, liveScope.workspaceID != workspaceID { throw ArchiveError.invalidIdentity }
        let listing: CaptureMediaArchiveListing
        do {
            let readable = try await CaptureMediaStore.shared.archiveListing(workspaceID: workspaceID, authorize: authorize)
            listing = liveScope?.filtering(readable) ?? readable
        }
        catch {
            guard authorize() else { throw ArchiveError.unavailable }
            // Optional source-store failure does not hide healthy domain records.
            listing = CaptureMediaArchiveListing(unavailableCount: 1)
        }
        guard authorize() else { throw ArchiveError.unavailable }
        for index in 0..<listing.unavailableCount {
            unavailableRecords.append(RecordsUnavailableRecord(origin: "media/" + workspaceID.uuidString, recordID: "unavailable-\(index)",
                title: recordsText("Source reference"), reason: .unreadableStorage))
        }
        return listing
    }
    private func recoveredSnapshot(_ saved: RecoveredRecord, authorize: @escaping RecordsToolsModel.Authorization) async throws -> [ArchiveRecord] {
        guard let registry, let directory, UUID(uuidString: saved.id) != nil else { throw ArchiveError.invalidIdentity }
        let lease = try await recoveryLifetime.begin(copy: saved, registry: registry, authorize: authorize)
        defer { recoveryLifetime.finish(lease) }
        let authorize = lease.authorize
        let folder = directory.appendingPathComponent("Recoveries", isDirectory: true).appendingPathComponent(saved.id, isDirectory: true)
        let filename: String
        switch saved.record.kind {
        case .comparison: filename = "comparison.sqlite"
        case .ledger: filename = "ledger.sqlite"
        case .pickup: filename = "pickup.sqlite"
        case .recipe, .sharedShop, .sharedHistory:
            do { try RecordsNativeCodec.validate(saved.record); return saved.record.nativePayload == nil ? [] : [saved.record] }
            catch { return omitRecovered(saved, reason: .invalidNative) }
        }
        let url = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            do { try RecordsNativeCodec.validate(saved.record); return [saved.record] }
            catch { return omitRecovered(saved, reason: .invalidNative) }
        }
        if saved.record.kind == .ledger {
            let opened = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: authorize)
            let store = opened.store
            let current = try await store.load()
            try await store.close()
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            guard authorize() else { throw ArchiveError.unavailable }
            guard let current else { return omitRecovered(saved, reason: .unreadableStorage) }
            do {
            let sources = try await mediaListing(workspaceID: opened.scope.workspaceID, authorize: authorize, liveScope: opened.scope).records
            return try RecordsNativeCodec.recoveredLedger(saved, current: current, scope: opened.scope, sources: sources)
            } catch { return omitRecovered(saved, reason: .invalidNative) }
        }
        let store: ComparisonStore
        let liveScope: RecordsRecoveryCapture.Scope?
        if saved.record.kind == .pickup {
            let opened = try await RecordsRecoveryCapture.openPickup(copy: saved, directory: folder, authorize: authorize)
            store = opened.store; liveScope = opened.scope
        } else { store = try ComparisonStore(url: url); liveScope = nil }
        let listing = try await store.listing()
        try await store.close()
        try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
        guard authorize() else { throw ArchiveError.unavailable }
        if listing.records.isEmpty && listing.unavailable.isEmpty { return omitRecovered(saved, reason: .unreadableStorage) }
        let batch = RecordsSnapshotProjection.project(listing, origin: saved.record.origin, localCopyID: saved.id) { current in
            if saved.record.kind == .comparison {
                let value = try RecordsNativeCodec.comparison(current.payload), bytes = try RecordsNativeCodec.canonical(value)
                guard value.draft.id == current.id else { throw ArchiveError.invalidIdentity }
                return try RecordsNativeCodec.revised(saved.record, nativePayload: bytes, id: current.id.uuidString, title: value.draft.item, date: current.savedAt,
                    lines: [HelperLine(label: value.draft.item, originalAmount: value.draft.needed, originalUnit: value.draft.unit.rawValue)])
            }
            let value = try RecordsNativeCodec.pickup(current.payload), bytes = try RecordsNativeCodec.canonical(value)
            guard value.id == current.id else { throw ArchiveError.invalidIdentity }
            let lines = (value.basket?.current.lines ?? []).map { HelperLine(label: $0.name, originalAmount: $0.quantity.originalLiteral, originalUnit: $0.quantity.unit.rawValue) }
            return try RecordsNativeCodec.revised(saved.record, nativePayload: bytes, id: current.id.uuidString, title: current.title, date: current.savedAt, lines: lines)
        }
        unavailableRecords += batch.unavailable
        if let liveScope {
            let sources = try await mediaListing(workspaceID: liveScope.workspaceID, authorize: authorize, liveScope: liveScope).records
            return try batch.records.map { try RecordsMediaCodec.attaching(sources, to: $0, liveScope: liveScope) }
        }
        return batch.records
    }
    private func omitRecovered(_ saved: RecoveredRecord, reason: RecordsUnavailableRecord.Reason) -> [ArchiveRecord] {
        unavailableRecords.append(RecordsUnavailableRecord(origin: saved.record.origin, recordID: saved.record.id, title: saved.record.title, reason: reason, localCopyID: saved.id))
        return []
    }
    private func validate(_ record: ArchiveRecord) async throws {
        guard let authorize = captureAuthorization(), authorize() else { throw ArchiveError.unavailable }
        try await synchronizeErasure()
        guard authorize() else { throw ArchiveError.unavailable }
        for attachment in record.media ?? [] {
            let source = try RecordsMediaCodec.decode(attachment)
            let retired = try await CaptureMediaStore.shared.isRetired(source)
            guard !retired else { throw ArchiveError.conflict }
            guard authorize() else { throw ArchiveError.unavailable }
        }
        if let pending = ledger.pendingLedgerDeletionReview, record.origin == "ledger/" + pending.workspaceID.uuidString {
            throw ArchiveError.unavailable
        }
        if let store = app.store, record.origin == "comparisons/" + store.workspaceID.uuidString,
           let id = UUID(uuidString: record.id), try await store.isErased(id: id) { throw ArchiveError.conflict }
        if record.origin == pickupOrigin, let id = UUID(uuidString: record.id),
           try await pickup.archiveTombstones().contains(where: { $0.id == id }) { throw ArchiveError.conflict }
        try RecordsNativeCodec.validate(record)
    }
    func deleteWholeLedger(_ review: WholeLedgerDeletionReview) async throws {
        guard !deletingLedger, let registry else { throw ArchiveError.unavailable }
        deletingLedger = true; defer { deletingLedger = false }
        tools?.invalidateForSourceErasure()
        // Keep the same deletion intent until both durable erasure and all local
        // recovery projections/workspaces have been reconciled successfully.
        try await RecordsLedgerErasure.complete(review, ledger: ledger, registry: registry, cleanup: erasureCleanup) {
            try await self.purgeOrphanWorkspaces()
        }
        await tools?.refresh()
    }
    private func delete(_ record: ArchiveRecord) async throws {
        if record.kind == .pickup {
            let snapshot = try await pickup.archiveSnapshot()
            guard record.origin == "pickups/" + snapshot.workspaceID.uuidString,
                  let saved = snapshot.records.first(where: { $0.id.uuidString == record.id }) else { throw ArchiveError.unavailable }
            let bytes = try RecordsNativeCodec.canonical(RecordsNativeCodec.pickup(saved.payload))
            guard ArchiveCodec.digest(bytes) == record.revision else { throw ArchiveError.staleReview }
            try await pickup.deleteArchived(id: saved.id, expectedRevision: saved.revision, operationID: UUID())
            try await synchronizeErasure()
            return
        }
        guard record.kind == .comparison, let store = app.store,
              record.origin == "comparisons/" + store.workspaceID.uuidString,
              let id = UUID(uuidString: record.id), let saved = try await store.load(id: id) else { throw ArchiveError.unavailable }
        let bytes = try RecordsNativeCodec.canonical(RecordsNativeCodec.comparison(saved.payload))
        guard ArchiveCodec.digest(bytes) == record.revision else { throw ArchiveError.staleReview }
        _ = try await store.erase(id: id, expectedRevision: saved.revision, operationID: UUID(), at: Date())
        try await synchronizeErasure()
        await app.refresh()
    }
    private func open(_ saved: RecoveredRecord) async throws {
        guard let baseAuthorize = captureAuthorization(), baseAuthorize() else { throw ArchiveError.unavailable }
        try await validate(saved.record)
        guard baseAuthorize() else { throw ArchiveError.unavailable }
        guard let registry, let directory, let current = try await registry.refreshList().first(where: { $0.id == saved.id }), current == saved,
              let localID = UUID(uuidString: saved.id), let bytes = saved.record.nativePayload else { throw ArchiveError.unavailable }
        guard baseAuthorize() else { throw ArchiveError.unavailable }
        let lease = try await recoveryLifetime.begin(copy: saved, registry: registry, authorize: baseAuthorize)
        defer { recoveryLifetime.finish(lease) }
        let authorize = lease.authorize
        if saved.record.kind == .recipe {
            let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: bytes).validated()
            destination = Destination(id: saved.id, content: .recipe(recipe)); return
        }
        let folder = directory.appendingPathComponent("Recoveries", isDirectory: true).appendingPathComponent(localID.uuidString, isDirectory: true)
        try protectDirectory(folder)
        switch saved.record.kind {
        case .comparison:
            let payload = try RecordsNativeCodec.comparison(bytes)
            let url = folder.appendingPathComponent("comparison.sqlite")
            let store = try ComparisonStore(url: url)
            if try await store.load(id: payload.draft.id) == nil {
                try await store.save(id: payload.draft.id, title: payload.draft.item, payload: bytes, savedAt: Date(timeIntervalSince1970: Double(saved.record.savedAtMilliseconds) / 1000))
            }
            try await store.close()
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            let isolated = AppModel(databaseURL: url); await isolated.open()
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            guard authorize(), isolated.ready, let record = isolated.records.first else { throw ArchiveError.unavailable }
            destination = Destination(id: saved.id, content: .comparison(isolated, try isolated.decode(record), record.savedAt))
        case .ledger:
            _ = try RecordsNativeCodec.ledger(bytes)
            let url = folder.appendingPathComponent("ledger.sqlite")
            let store = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: authorize).store
            if try await store.load() == nil { try await store.save(payload: bytes, expectedRevision: 0, operationID: UUID(), savedAt: Date(timeIntervalSince1970: Double(saved.record.savedAtMilliseconds) / 1000)) }
            try await store.close()
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            let isolated = LedgerModel(databaseURL: url); await isolated.open()
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            guard authorize(), isolated.ready else { throw ArchiveError.unavailable }
            destination = Destination(id: saved.id, content: .ledger(isolated))
        case .pickup:
            let value = try RecordsNativeCodec.pickup(bytes)
            let url = folder.appendingPathComponent("pickup.sqlite")
            let store = try await RecordsRecoveryCapture.openPickup(copy: saved, directory: folder, authorize: authorize).store
            if try await store.load(id: value.id) == nil { try await store.save(id: value.id, title: saved.record.title, payload: bytes, savedAt: value.savedAt) }
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            let isolated = PickupModel(store: store, databaseURL: url); await isolated.load()
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            guard authorize(), isolated.ready else { throw ArchiveError.unavailable }
            isolated.selectedID = value.id
            destination = Destination(id: saved.id, content: .pickup(isolated))
        case .sharedHistory:
            _ = try SharedHistoryArchiveAdapter.validate(saved.record)
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            guard authorize() else { throw ArchiveError.unavailable }
            destination = Destination(id: saved.id, content: .sharedRecord(saved.record, try SharedHistoryArchiveAdapter.readable(saved.record)))
        case .sharedShop:
            _ = try SharedRecordArchiveAdapter.validate(saved.record)
            try await recoveryLifetime.revalidate(lease, copy: saved, registry: registry)
            guard authorize() else { throw ArchiveError.unavailable }
            destination = Destination(id: saved.id, content: .sharedRecord(saved.record, try SharedRecordArchiveAdapter.readable(saved.record)))
        case .recipe: break
        }
    }
}

private struct RecordsLedgerDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ledger: LedgerModel
    let review: WholeLedgerDeletionReview
    let erase: () async throws -> Void
    @State private var attempting = false
    @State private var completed = false
    @State private var needsReview = false
    @State private var failure: String?
    private var effectiveReview: WholeLedgerDeletionReview { ledger.pendingLedgerDeletionReview ?? review }
    var body: some View {
        Form {
            Section {
                Text(recordsText("Delete the entire local ledger")).font(.title2.bold())
                Text(recordsText("This permanently deletes every shopping list, dinner plan, reusable dinner and saved revision in this ledger."))
                Text(String(format: recordsText("%lld shopping lists · %lld reusable dinners"), Int64(effectiveReview.shopCount), Int64(effectiveReview.reusableDinnerCount)))
                Text(recordsText("Pack comparisons, pickup histories, imported recipe source files and files already shared are kept."))
                    .font(.footnote)
                Text(recordsText("Recovered copies from this ledger are also removed. An old backup cannot restore this retired ledger on this iPhone."))
                    .font(.footnote)
                Text(recordsText("This cannot be undone. Export anything you want to keep before continuing."))
                    .font(.headline)
            }
            if completed {
                Section { Text(recordsText("The reviewed ledger and its history were deleted. You can start a new ledger in Shop.")) }
            } else {
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
                if ledger.hasPendingLedgerDeletion {
                    Section { Text(recordsText("This deletion was already confirmed. Retry finishes the same operation; it does not delete a newer ledger.")) }
                }
                if attempting { ProgressView(recordsText("Deleting the reviewed ledger…")) }
                else if needsReview {
                    Button(recordsText("Close and review again")) { dismiss() }
                } else {
                    Button(recordsText(ledger.hasPendingLedgerDeletion ? "Retry confirmed ledger deletion" : "Permanently delete entire ledger"), role: .destructive) {
                        Task {
                            attempting = true; failure = nil
                            defer { attempting = false }
                            do { try await erase(); completed = true }
                            catch LedgerDeletionError.staleReview {
                                needsReview = true
                                failure = recordsText("The ledger changed after review. Nothing was deleted. Review the entire ledger again.")
                            } catch {
                                failure = recordsText("Deletion or recovery cleanup is pending. Retry the same confirmed operation.")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(recordsText("Entire ledger deletion"))
        .interactiveDismissDisabled(attempting)
    }
}

private struct RecordsRecipeAdoptionView: View {
    let recipe: ImportedRecipe
    @ObservedObject var ledger: LedgerModel
    @State private var editing = false
    private var template: MealTemplate {
        // The placeholder is never shown or saved. The editor requires the person to
        // enter positive servings; original yield and ingredient words remain intact.
        MealTemplate(title: recipe.title, servings: .one,
            ingredients: recipe.ingredients.map { MealIngredient(name: $0, quantity: nil) },
            notes: ([recipe.yieldText, recipe.notes] + recipe.steps).filter { !$0.isEmpty }.joined(separator: "\n"), sourceURL: recipe.sourceURL)
    }
    var body: some View {
        Form {
            Text(recipe.title).font(.title2.bold())
            Text(recipe.yieldText)
            ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, value in Text(value) }
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { _, value in Text(value) }
            Text(recipe.notes)
            if let source = recipe.sourceURL { Text(source).textSelection(.enabled) }
            Text(recordsText("Original ingredient and yield text stays saved. Review servings and ingredient quantities before choosing this dinner."))
            if let shop = ledger.shop {
                Text(shop.title)
                Button(recordsText("Review for this pickup")) { editing = true }
                    .disabled(!ledger.ready || ledger.saving || ledger.hasPendingSave)
            } else {
                Text(recordsText("Start a pickup in Shop to choose this saved recipe. The original recipe remains here."))
            }
        }
        .navigationTitle(recordsText("Saved recipe"))
        .sheet(isPresented: $editing) {
            NavigationStack { LedgerMealEditor(model: ledger, template: template, chooseNow: true, servingsUnknown: true) }
        }
    }
}
