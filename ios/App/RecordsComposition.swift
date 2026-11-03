import SwiftUI
import Foundation
import CoreDomain
import LocalStore
import RecordArchive

/// The records boundary owns explicit domain projections. Databases, credentials,
/// consent, membership and grants are never archive payloads.
private struct RecordsLedgerDocument: Codable {
    let formatVersion: Int
    let workspace: LedgerWorkspace
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
    static func pickup(_ data: Data) throws -> PickupJourney {
        try ArchiveCodec.preflight(data)
        let value = try JSONDecoder().decode(PickupJourney.self, from: data)
        try PickupModel.validate(value)
        return value
    }
    static func validate(_ record: ArchiveRecord) throws {
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
            normalized = try canonical(RecordsLedgerDocument(formatVersion: 1, workspace: workspace))
        case .pickup:
            let value = try pickup(bytes)
            guard value.id.uuidString == record.id else { throw ArchiveError.invalidIdentity }
            normalized = try canonical(value)
        case .recipe:
            let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: bytes).validated()
            normalized = try ArchiveCodec.canonical(recipe)
        }
        // Re-encoding the typed domain allowlist rejects extra keys at every depth.
        guard bytes == normalized else { throw ArchiveError.unsupportedRecord }
    }
}

struct RecordsToolsEntryView: View {
    @StateObject private var composition: RecordsComposition
    init(app: AppModel, ledger: LedgerModel, pickup: PickupModel) {
        _composition = StateObject(wrappedValue: RecordsComposition(app: app, ledger: ledger, pickup: pickup))
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
        .task { await composition.load() }
        .sheet(item: $composition.destination, onDismiss: { Task { await composition.tools?.refresh() } }) { destination in
            NavigationStack {
                Group {
                    switch destination.content {
                    case let .comparison(app, draft, date): ComparisonView(draft: draft, savedAt: date).environmentObject(app)
                    case let .ledger(model):
                        List {
                            Text(recordsText("This is a separate recovered workspace. Your current pickup is unchanged."))
                            NavigationLink(recordsText("Open recovered shopping list")) { LedgerHomeView(model: model) }
                            NavigationLink(recordsText("Open recovered dinners")) { LedgerMealsView(model: model) }
                        }.navigationTitle(recordsText("Recovered workspace"))
                    case let .pickup(model): PickupHomeView(model: model).environment(\.pickupLedger, nil)
                    case let .recipe(recipe): RecordsRecipeAdoptionView(recipe: recipe, ledger: composition.ledger)
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(recordsText("Done")) { composition.destination = nil } } }
            }
        }
    }
}

@MainActor private final class RecordsComposition: ObservableObject {
    struct Destination: Identifiable {
        enum Content { case comparison(AppModel, ComparisonDraft, Date), ledger(LedgerModel), pickup(PickupModel), recipe(ImportedRecipe) }
        let id: String
        let content: Content
    }
    @Published var tools: RecordsToolsModel?
    @Published var destination: Destination?
    @Published var error: ArchiveError?
    let app: AppModel
    let ledger: LedgerModel
    let pickup: PickupModel
    private var registry: RecoveryRegistry?
    private var directory: URL?
    private var loading = false
    private var pickupOrigin: String?
    init(app: AppModel, ledger: LedgerModel, pickup: PickupModel) { self.app = app; self.ledger = ledger; self.pickup = pickup }
    func load() async {
        guard tools == nil, !loading else { return }
        loading = true; defer { loading = false }
        do {
            await app.open(); await ledger.open(); await pickup.load()
            guard app.ready, ledger.ready, pickup.ready else { throw ArchiveError.unavailable }
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
            try await synchronizeErasure()
            pickupOrigin = "pickups/" + (try await pickup.archiveSnapshot()).workspaceID.uuidString
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
            })
            error = nil
        } catch { self.error = error as? ArchiveError ?? .unavailable }
    }
    private func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    private func synchronizeErasure() async throws {
        guard let registry, let store = app.store else { throw ArchiveError.unavailable }
        let tombstones = try await store.tombstones()
        let pickupTombstones = try await pickup.archiveTombstones()
        let erased = tombstones.map { ArchiveSourceIdentity(origin: "comparisons/" + $0.workspaceID.uuidString, recordID: $0.id.uuidString) }
            + pickupTombstones.map { ArchiveSourceIdentity(origin: "pickups/" + $0.workspaceID.uuidString, recordID: $0.id.uuidString) }
        try await registry.registerErasedSources(erased)
        try await purgeOrphanWorkspaces()
    }
    private func purgeOrphanWorkspaces() async throws {
        guard let registry, let directory else { throw ArchiveError.unavailable }
        let root = directory.appendingPathComponent("Recoveries", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let retained = Set(try await registry.refreshList().map(\.id))
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: url.lastPathComponent) != nil, !retained.contains(url.lastPathComponent) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
    private func snapshot() async throws -> [ArchiveRecord] {
        try await synchronizeErasure()
        guard let store = app.store else { throw ArchiveError.unavailable }
        var result: [ArchiveRecord] = []
        for saved in try await store.list() {
            let payload = try RecordsNativeCodec.comparison(saved.payload)
            let bytes = try RecordsNativeCodec.canonical(payload)
            let draft = payload.draft
            result.append(ArchiveRecord(id: saved.id.uuidString, origin: "comparisons/" + store.workspaceID.uuidString,
                revision: ArchiveCodec.digest(bytes), kind: .comparison, title: draft.item,
                savedAtMilliseconds: ArchiveCodec.milliseconds(saved.savedAt),
                helperLines: [HelperLine(label: draft.item, originalAmount: draft.needed, originalUnit: draft.unit.rawValue)], nativePayload: bytes))
        }
        let workspace = try RecordsNativeCodec.ledger(ledger.exportPayload())
        if let originID = ledger.sourceWorkspaceID {
            for shop in workspace.shops {
                let scoped = LedgerWorkspace(shops: [shop], mealTemplates: [], selectedShopID: shop.id)
                let bytes = try RecordsNativeCodec.canonical(RecordsLedgerDocument(formatVersion: 1, workspace: scoped))
                let lines = shop.contributions.filter { $0.removedAt == nil }.map { contribution in
                    HelperLine(label: contribution.productName, originalAmount: contribution.quantity?.originalLiteral ?? "",
                               originalUnit: contribution.quantity?.unit.rawValue ?? "")
                }
                result.append(ArchiveRecord(id: shop.id.uuidString, origin: "ledger/" + originID.uuidString,
                    revision: ArchiveCodec.digest(bytes), kind: .ledger, title: shop.title,
                    savedAtMilliseconds: ArchiveCodec.milliseconds(ledger.savedAt ?? Date(timeIntervalSince1970: 0)), helperLines: lines, nativePayload: bytes))
            }
            if !workspace.mealTemplates.isEmpty {
                let library = LedgerWorkspace(mealTemplates: workspace.mealTemplates)
                let bytes = try RecordsNativeCodec.canonical(RecordsLedgerDocument(formatVersion: 1, workspace: library))
                result.append(ArchiveRecord(id: "meal-library", origin: "ledger/" + originID.uuidString,
                    revision: ArchiveCodec.digest(bytes), kind: .ledger, title: "Reusable dinners",
                    savedAtMilliseconds: ArchiveCodec.milliseconds(ledger.savedAt ?? Date(timeIntervalSince1970: 0)), nativePayload: bytes))
            }
        }
        let pickupSnapshot = try await pickup.archiveSnapshot()
        for saved in pickupSnapshot.records {
            let value = try RecordsNativeCodec.pickup(saved.payload)
            let bytes = try RecordsNativeCodec.canonical(value)
            let lines = (value.basket?.current.lines ?? []).map { line in
                HelperLine(label: line.name, originalAmount: line.quantity.originalLiteral, originalUnit: line.quantity.unit.rawValue)
            }
            result.append(ArchiveRecord(id: saved.id.uuidString, origin: "pickups/" + pickupSnapshot.workspaceID.uuidString,
                revision: ArchiveCodec.digest(bytes), kind: .pickup,
                title: value.basket?.current.lines.first?.name ?? value.urgent.first?.meal ?? "Pickup",
                savedAtMilliseconds: ArchiveCodec.milliseconds(saved.savedAt), helperLines: lines, nativePayload: bytes))
        }
        // A separately recovered workspace may have been edited since import. Export
        // its committed domain state, retaining the original source identity and parent.
        if let registry {
            for saved in try await registry.refreshList() { result += try await recoveredSnapshot(saved) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert(RecordsToolsModel.selectionID($0)).inserted }
    }
    private func recoveredSnapshot(_ saved: RecoveredRecord) async throws -> [ArchiveRecord] {
        guard let directory, UUID(uuidString: saved.id) != nil else { throw ArchiveError.invalidIdentity }
        let folder = directory.appendingPathComponent("Recoveries", isDirectory: true).appendingPathComponent(saved.id, isDirectory: true)
        let filename: String
        switch saved.record.kind {
        case .comparison: filename = "comparison.sqlite"
        case .ledger: filename = "ledger.sqlite"
        case .pickup: filename = "pickup.sqlite"
        case .recipe: return saved.record.nativePayload == nil ? [] : [saved.record]
        }
        let url = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [saved.record] }
        func revised(_ bytes: Data, id: String, title: String, date: Date, lines: [HelperLine]) -> ArchiveRecord {
            var record = saved.record
            record.id = id; record.title = title; record.helperLines = lines; record.nativePayload = bytes
            record.revision = ArchiveCodec.digest(bytes)
            record.parentRevision = record.revision == saved.record.revision ? saved.record.parentRevision : saved.record.revision
            record.savedAtMilliseconds = record.revision == saved.record.revision ? saved.record.savedAtMilliseconds : ArchiveCodec.milliseconds(date)
            return record
        }
        if saved.record.kind == .ledger {
            let store = try LedgerStore(url: url)
            let current = try await store.load()
            try await store.close()
            guard let current else { throw ArchiveError.unavailable }
            let workspace = try RecordsNativeCodec.ledger(current.payload)
            var result = try workspace.shops.map { shop in
                let scoped = LedgerWorkspace(shops: [shop], mealTemplates: [], selectedShopID: shop.id)
                let bytes = try RecordsNativeCodec.canonical(RecordsLedgerDocument(formatVersion: 1, workspace: scoped))
                let lines = shop.contributions.filter { $0.removedAt == nil }.map {
                    HelperLine(label: $0.productName, originalAmount: $0.quantity?.originalLiteral ?? "", originalUnit: $0.quantity?.unit.rawValue ?? "")
                }
                return revised(bytes, id: shop.id.uuidString, title: shop.title, date: current.savedAt, lines: lines)
            }
            if !workspace.mealTemplates.isEmpty {
                let library = LedgerWorkspace(mealTemplates: workspace.mealTemplates)
                let bytes = try RecordsNativeCodec.canonical(RecordsLedgerDocument(formatVersion: 1, workspace: library))
                result.append(revised(bytes, id: "meal-library", title: "Reusable dinners", date: current.savedAt, lines: []))
            }
            return result
        }
        let store = try ComparisonStore(url: url)
        let records = try await store.list()
        try await store.close()
        return try records.map { current in
            if saved.record.kind == .comparison {
                let value = try RecordsNativeCodec.comparison(current.payload), bytes = try RecordsNativeCodec.canonical(value)
                return revised(bytes, id: current.id.uuidString, title: value.draft.item, date: current.savedAt,
                    lines: [HelperLine(label: value.draft.item, originalAmount: value.draft.needed, originalUnit: value.draft.unit.rawValue)])
            }
            let value = try RecordsNativeCodec.pickup(current.payload), bytes = try RecordsNativeCodec.canonical(value)
            let lines = (value.basket?.current.lines ?? []).map { HelperLine(label: $0.name, originalAmount: $0.quantity.originalLiteral, originalUnit: $0.quantity.unit.rawValue) }
            return revised(bytes, id: current.id.uuidString, title: current.title, date: current.savedAt, lines: lines)
        }
    }
    private func validate(_ record: ArchiveRecord) async throws {
        try await synchronizeErasure()
        if let store = app.store, record.origin == "comparisons/" + store.workspaceID.uuidString,
           let id = UUID(uuidString: record.id), try await store.isErased(id: id) { throw ArchiveError.conflict }
        if record.origin == pickupOrigin, let id = UUID(uuidString: record.id),
           try await pickup.archiveTombstones().contains(where: { $0.id == id }) { throw ArchiveError.conflict }
        try RecordsNativeCodec.validate(record)
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
        try await validate(saved.record)
        guard let registry, let directory, let current = try await registry.refreshList().first(where: { $0.id == saved.id }), current == saved,
              let localID = UUID(uuidString: saved.id), let bytes = saved.record.nativePayload else { throw ArchiveError.unavailable }
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
            let isolated = AppModel(databaseURL: url); await isolated.open()
            guard isolated.ready, let record = isolated.records.first else { throw ArchiveError.unavailable }
            destination = Destination(id: saved.id, content: .comparison(isolated, try isolated.decode(record), record.savedAt))
        case .ledger:
            _ = try RecordsNativeCodec.ledger(bytes)
            let url = folder.appendingPathComponent("ledger.sqlite"), store = try LedgerStore(url: folder.appendingPathComponent("ledger.sqlite"))
            if try await store.load() == nil { try await store.save(payload: bytes, expectedRevision: 0, operationID: UUID(), savedAt: Date(timeIntervalSince1970: Double(saved.record.savedAtMilliseconds) / 1000)) }
            try await store.close()
            let isolated = LedgerModel(databaseURL: url); await isolated.open()
            guard isolated.ready else { throw ArchiveError.unavailable }
            destination = Destination(id: saved.id, content: .ledger(isolated))
        case .pickup:
            let value = try RecordsNativeCodec.pickup(bytes)
            let url = folder.appendingPathComponent("pickup.sqlite"), store = try ComparisonStore(url: folder.appendingPathComponent("pickup.sqlite"))
            if try await store.load(id: value.id) == nil { try await store.save(id: value.id, title: saved.record.title, payload: bytes, savedAt: value.savedAt) }
            let isolated = PickupModel(store: store, databaseURL: url); await isolated.load()
            guard isolated.ready else { throw ArchiveError.unavailable }
            isolated.selectedID = value.id
            destination = Destination(id: saved.id, content: .pickup(isolated))
        case .recipe: break
        }
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
