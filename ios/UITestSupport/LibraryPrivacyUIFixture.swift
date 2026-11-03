#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import CoreDomain
import RecordArchive

/// Fictional documented Recipe JSON-LD input. The saved match and repeated row
/// exercise content matching; two unsupported shapes remain explicit skips.
enum RecipeLibraryUIFixtureSamples {
    static let existing = ImportedRecipe(title: "Existing family soup", yieldText: "4 bowls",
        ingredients: ["2 cups beans"], steps: ["Keep the existing instructions."],
        sourceURL: "https://recipe-import.invalid/existing", notes: "Keep this saved recipe")
    static let newTitle = "Arroz sin cambiar"
    static let newYield = "three plates + lunch"
    static let originalIngredient = "2 cans (15 oz) tomatoes"
    static let sourceURL = "https://recipe-import.invalid/arroz"

    static func libraryData() throws -> Data {
        let existingNode: [String: Any] = ["@type": "Recipe", "name": existing.title,
            "recipeYield": existing.yieldText, "recipeIngredient": existing.ingredients,
            "recipeInstructions": existing.steps, "url": existing.sourceURL!, "notes": existing.notes]
        let rice: [String: Any] = ["@type": "Recipe", "name": newTitle,
            "recipeYield": newYield, "recipeIngredient": [originalIngredient, "salt to taste"],
            "recipeInstructions": [["@type": "HowToStep", "text": "Keep the original words."]],
            "url": sourceURL, "notes": "Fictional library source", "nutrition": ["calories": "not imported"]]
        var repeatedRice = rice; repeatedRice.removeValue(forKey: "nutrition")
        let pasta: [String: Any] = ["@type": ["Recipe"], "name": "Lemon pasta",
            "recipeYield": "4 dinner portions", "recipeIngredient": ["pasta, amount not supplied", "one lemon"],
            "recipeInstructions": "Review the portions before choosing this dinner.",
            "url": "https://recipe-import.invalid/pasta"]
        let graph: [Any] = [existingNode, rice, repeatedRice, pasta,
            ["@type": "Person", "name": "Skipped non-recipe"],
            ["@type": "Recipe", "name": "Skipped numeric yield", "recipeYield": 4]]
        return try JSONSerialization.data(withJSONObject: ["@context": "https://unreachable.invalid/context",
            "formatVersion": 1, "@graph": graph], options: [.sortedKeys])
    }
}

@MainActor private final class LibraryPrivacyUIFixtureState: ObservableObject {
    enum Mode: String { case recipes, corrections }
    let mode: Mode
    let app: AppModel
    let ledger: LedgerModel
    let pickup: PickupModel
    let household: HouseholdModel
    let access: WorkspaceAccess
    let surfaces: DeviceSurfacesComposition
    let membership = MembershipCoordinator()
    @Published private(set) var ready = false
    @Published private(set) var failed = false
    @Published private(set) var sourceUnchanged = false
    @Published private(set) var recoveredCount = 0
    @Published private(set) var existingRecipePreserved = false
    @Published private(set) var englishCount = 0
    @Published private(set) var spanishCount = 0
    @Published private(set) var englishEnabled = false
    @Published private(set) var spanishEnabled = false
    @Published private(set) var fileSelections = 0
    @Published var corruptFileSelected = false
    private let directory: URL
    private let recordsDirectory: URL
    private let libraryFile: URL
    private let corruptFile: URL
    private let retiredCorrectionWorkspace: UUID?
    private var registry: RecoveryRegistry?
    private var existingRecipeCopy: RecoveredRecord?
    private var originalLedger: Data?
    private var correctionWorkspace: UUID?

    init(mode: Mode) {
        self.mode = mode
        let arguments = ProcessInfo.processInfo.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let uiDirectory = support.appendingPathComponent("UITestWorkspace", isDirectory: true)
        let directory = uiDirectory.appendingPathComponent("LibraryPrivacyFixture/" + mode.rawValue, isDirectory: true)
        self.directory = directory
        recordsDirectory = uiDirectory.appendingPathComponent("Records", isDirectory: true)
        libraryFile = directory.appendingPathComponent("documented-library.jsonld")
        corruptFile = directory.appendingPathComponent("corrupt-library.jsonld")
        let defaultsName = "dev.roominthecart.library-privacy-ui-fixture." + mode.rawValue
        let defaults = UserDefaults(suiteName: defaultsName)!
        let modeArgument = mode == .recipes ? "--recipe-library-fixture" : "--correction-privacy-fixture"
        let reset = arguments.contains("--ui-testing") && arguments.contains(modeArgument) && arguments.contains("--reset-library-privacy-fixture")
        let oldWorkspace = (try? Data(contentsOf: directory.appendingPathComponent("correction-workspace.txt")))
            .flatMap { String(data: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:))
        retiredCorrectionWorkspace = reset ? oldWorkspace : nil
        if reset {
            try? FileManager.default.removeItem(at: directory)
            // RecordsComposition intentionally owns this test-only registry path.
            // These fixtures run sequentially on the reserved test installation.
            if mode == .recipes { try? FileManager.default.removeItem(at: recordsDirectory) }
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        let disconnectedBundleURL = directory.appendingPathComponent("Disconnected.bundle", isDirectory: true)
        try? FileManager.default.createDirectory(at: disconnectedBundleURL, withIntermediateDirectories: true)
        let disconnectedInfo = try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": defaultsName], format: .xml, options: 0)
        try? disconnectedInfo?.write(to: disconnectedBundleURL.appendingPathComponent("Info.plist"))
        let disconnected = Bundle(path: disconnectedBundleURL.path)!
        app = AppModel(databaseURL: directory.appendingPathComponent("comparisons.sqlite"))
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        household = HouseholdModel(bundle: disconnected, outboxURL: directory.appendingPathComponent("unused-local-outbox.json"))
        access = WorkspaceAccess(defaults: defaults)
        surfaces = DeviceSurfacesComposition(directory: directory.appendingPathComponent("surfaces", isDirectory: true),
            bundle: disconnected, launchArguments: arguments)
    }

    var fileAdapter: RecordsMediaUITestFileAdapter {
        RecordsMediaUITestFileAdapter(save: { _ in throw ArchiveError.unavailable }, selectedURL: { [weak self] in
            guard let self else { return nil }
            self.fileSelections += 1
            return self.corruptFileSelected ? self.corruptFile : self.libraryFile
        })
    }
    var erasureCleanup: RecordsErasureCleanup {
        RecordsErasureCleanup(eraseLedgerWorkspace: { [weak self] id in
            guard let self else { throw ArchiveError.unavailable }
            try await self.surfaces.eraseLedgerWorkspace(id)
            try await CaptureCorrectionStore.shared.eraseProfile(CaptureCorrectionScope(profileID: "local:" + id.uuidString, localeIdentifier: "en-US"))
        }, erasePickupRecord: { [weak self] workspaceID, recordID in
            guard let self else { throw ArchiveError.unavailable }
            try await self.surfaces.erasePickupRecord(workspaceID: workspaceID, recordID: recordID)
        })
    }

    func start() async {
        let arguments = ProcessInfo.processInfo.arguments
        let expected = mode == .recipes ? "--recipe-library-fixture" : "--correction-privacy-fixture"
        guard !ready, !failed, arguments.contains("--ui-testing"), arguments.contains(expected) else { return }
        do {
            if let retiredCorrectionWorkspace {
                try await CaptureCorrectionStore.shared.eraseProfile(CaptureCorrectionScope(
                    profileID: "local:" + retiredCorrectionWorkspace.uuidString, localeIdentifier: "en-US"))
            }
            await app.open(); await ledger.open(); await pickup.load()
            guard app.ready, ledger.ready, pickup.ready, access.unlocked, !household.configured,
                  CapturePrivateIdentity.current(access: access, household: household) != nil else { throw ArchiveError.unavailable }
            if ledger.workspace.shops.isEmpty {
                var shop = ShoppingLedger(title: mode == .recipes ? "E01 unchanged local pickup" : "N04 unchanged local pickup")
                _ = try shop.addManualLine(name: "Private fixture beans", quantity: Quantity(amount: Rational(2), unit: .count, originalLiteral: "2 cans"))
                guard await ledger.change(key: "library-privacy-fixture-seed", { $0 = LedgerWorkspace(shops: [shop], selectedShopID: shop.id) }) else { throw ArchiveError.unavailable }
            }
            originalLedger = try RecordsNativeCodec.canonical(RecordsNativeCodec.ledger(ledger.exportPayload()))
            surfaces.bind(ledger: ledger, pickup: pickup, household: household, access: access)
            await surfaces.foreground()
            membership.bind(to: household)
            guard surfaces.privateAuthorized else { throw ArchiveError.unavailable }
            if mode == .recipes { try await seedRecipes() } else { try await seedCorrections() }
            try await refreshEvidence()
            ready = true
        } catch { failed = true }
    }

    private func seedRecipes() async throws {
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        let registry = try RecoveryRegistry(url: recordsDirectory.appendingPathComponent("recovery-v1.json"))
        self.registry = registry
        let record = try RecipeLibraryUIFixtureSamples.existing.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0))
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "recipe-library-v1", revision: record.revision)
        let seeded = try await registry.apply(registry.review(envelope))
        existingRecipeCopy = seeded.records.first
        let input = try RecipeLibraryUIFixtureSamples.libraryData()
        let report = try RecipeImporter.stage(input, existing: [RecipeLibraryUIFixtureSamples.existing])
        guard report.recipes.count == 2, report.duplicateCount == 2, report.skippedRows == 2,
              report.unsupportedFields == ["nutrition"] else { throw ArchiveError.integrity }
        try input.write(to: libraryFile, options: [.atomic, .completeFileProtection])
        try Data(#"{"@type":"Recipe","name":"#.utf8).write(to: corruptFile, options: [.atomic, .completeFileProtection])
    }

    private func seedCorrections() async throws {
        guard let workspace = ledger.sourceWorkspaceID else { throw ArchiveError.unavailable }
        correctionWorkspace = workspace
        let marker = directory.appendingPathComponent("correction-workspace.txt")
        let previouslySeeded = (try? String(contentsOf: marker, encoding: .utf8)) == workspace.uuidString
        guard !previouslySeeded else { return }
        let english = CaptureCorrectionScope(profileID: "local:" + workspace.uuidString, localeIdentifier: "en-US")
        let spanish = CaptureCorrectionScope(profileID: english.profileID, localeIdentifier: "es-US")
        if try await CaptureCorrectionStore.shared.load(english).entries.isEmpty {
            try await CaptureCorrectionStore.shared.setEnabled(true, scope: english)
            try await CaptureCorrectionStore.shared.remember(original: "tortiyas", replacement: "tortillas", scope: english)
            try await CaptureCorrectionStore.shared.remember(original: "frijolles", replacement: "frijoles", scope: english)
        }
        if try await CaptureCorrectionStore.shared.load(spanish).entries.isEmpty {
            try await CaptureCorrectionStore.shared.setEnabled(true, scope: spanish)
            try await CaptureCorrectionStore.shared.remember(original: "yogurth", replacement: "yogur", scope: spanish)
        }
        try Data(workspace.uuidString.utf8).write(to: marker, options: [.atomic, .completeFileProtection])
    }

    func refreshEvidence() async throws {
        let unchanged = try RecordsNativeCodec.canonical(RecordsNativeCodec.ledger(ledger.exportPayload())) == originalLedger
        if sourceUnchanged != unchanged { sourceUnchanged = unchanged }
        if let registry, let existingRecipeCopy {
            let saved = try await registry.refreshList()
            let count = saved.filter { $0.record.kind == .recipe }.count
            let preserved = saved.contains(existingRecipeCopy)
            if recoveredCount != count { recoveredCount = count }
            if existingRecipePreserved != preserved { existingRecipePreserved = preserved }
        }
        if let workspace = correctionWorkspace {
            let english = try await CaptureCorrectionStore.shared.load(CaptureCorrectionScope(profileID: "local:" + workspace.uuidString, localeIdentifier: "en-US"))
            let spanish = try await CaptureCorrectionStore.shared.load(CaptureCorrectionScope(profileID: "local:" + workspace.uuidString, localeIdentifier: "es-US"))
            if englishCount != english.entries.count { englishCount = english.entries.count }
            if spanishCount != spanish.entries.count { spanishCount = spanish.entries.count }
            if englishEnabled != english.enabled { englishEnabled = english.enabled }
            if spanishEnabled != spanish.enabled { spanishEnabled = spanish.enabled }
        }
    }
}

struct RecipeLibraryUIFixtureRoot: View {
    @StateObject private var fixture = LibraryPrivacyUIFixtureState(mode: .recipes)
    var body: some View {
        VStack(spacing: 2) {
            Text("E01 saved recipes: \(fixture.recoveredCount)").font(.caption2).accessibilityIdentifier("fixture.library.recipeCount")
            Text("E01 original recipe preserved: \(fixture.existingRecipePreserved ? "yes" : "no")").font(.caption2).accessibilityIdentifier("fixture.library.existingPreserved")
            Text("E01 local source unchanged: \(fixture.sourceUnchanged ? "yes" : "no")").font(.caption2).accessibilityIdentifier("fixture.library.sourceUnchanged")
            HStack {
                Button("Use library picker input") { fixture.corruptFileSelected = false }.accessibilityIdentifier("fixture.library.selectLibrary")
                Button("Use corrupt picker input") { fixture.corruptFileSelected = true }.accessibilityIdentifier("fixture.library.selectCorrupt")
            }.buttonStyle(.bordered).font(.caption).frame(minHeight: 44)
            Text("E01 picker selections: \(fixture.fileSelections)").font(.caption2).accessibilityIdentifier("fixture.library.fileSelections")
            if fixture.ready {
                NavigationStack {
                    RecordsToolsEntryView(app: fixture.app, ledger: fixture.ledger, pickup: fixture.pickup, erasureCleanup: fixture.erasureCleanup)
                }
                .environmentObject(fixture.app).environmentObject(fixture.ledger).environmentObject(fixture.pickup)
                .environmentObject(fixture.household).environmentObject(fixture.access)
                .environment(\.recordsMediaUITestFiles, fixture.fileAdapter).tint(Theme.action)
            } else if fixture.failed { Text("E01 fixture failed").accessibilityIdentifier("fixture.library.failure") }
            else { ProgressView("Opening isolated E01 recipe fixture") }
        }
            .task { await fixture.start(); await monitor() }
    }
    private func monitor() async {
        while !Task.isCancelled, fixture.ready {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { try await fixture.refreshEvidence() } catch { return }
        }
    }
}

struct CorrectionPrivacyUIFixtureRoot: View {
    @StateObject private var fixture = LibraryPrivacyUIFixtureState(mode: .corrections)
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 2) {
            Text("N04 English entries: \(fixture.englishCount) · enabled: \(fixture.englishEnabled ? "yes" : "no")").font(.caption2).accessibilityIdentifier("fixture.corrections.english")
            Text("N04 Spanish entries: \(fixture.spanishCount) · enabled: \(fixture.spanishEnabled ? "yes" : "no")").font(.caption2).accessibilityIdentifier("fixture.corrections.spanish")
            Text("N04 local source unchanged: \(fixture.sourceUnchanged ? "yes" : "no")").font(.caption2).accessibilityIdentifier("fixture.corrections.sourceUnchanged")
            if fixture.ready {
                NavigationStack { SettingsView() }
                    .environmentObject(fixture.app).environmentObject(fixture.ledger).environmentObject(fixture.pickup)
                    .environmentObject(fixture.household).environmentObject(fixture.access)
                    .environmentObject(fixture.surfaces).environmentObject(fixture.membership).tint(Theme.action)
            } else if fixture.failed { Text("N04 fixture failed").accessibilityIdentifier("fixture.corrections.failure") }
            else { ProgressView("Opening isolated N04 privacy fixture") }
        }
            .task { await fixture.start(); await monitor() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { fixture.surfaces.background(); fixture.access.background(); fixture.household.lock() }
                if phase == .active { Task { await fixture.surfaces.foreground() } }
            }
    }
    private func monitor() async {
        while !Task.isCancelled, fixture.ready {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { try await fixture.refreshEvidence() } catch { return }
        }
    }
}
#endif
