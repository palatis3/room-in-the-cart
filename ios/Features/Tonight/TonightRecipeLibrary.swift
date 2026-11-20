import Foundation
import RecordArchive

/// The same protected registry used by Records. Imported text remains a source,
/// not an approved typed recipe and never silently gains quantities or servings.
@MainActor enum TonightRecipeLibrary {
    static func registryURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var folder = base.appendingPathComponent("RoomInTheCart", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            folder = base.appendingPathComponent("UITestWorkspace", isDirectory: true)
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--shopper-recipe-sources") {
                return folder.appendingPathComponent("ShopperRecipeFixture", isDirectory: true).appendingPathComponent("recovery-v1.json")
            }
            #endif
        }
        #endif
        return folder.appendingPathComponent("Records", isDirectory: true).appendingPathComponent("recovery-v1.json")
    }
    static func read(url: URL? = nil, authorize: @escaping () -> Bool) async throws -> [TonightMealModel.Source] {
        guard authorize() else { throw TonightMealModel.Failure.unavailable }
        let resolved: URL
        if let url { resolved = url } else { resolved = try registryURL() }
        let url = resolved
        // Browsing an empty library does not create a registry or a shopping list.
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let registry = try RecoveryRegistry(url: url)
        let records = try await registry.refreshList()
        guard authorize() else { throw TonightMealModel.Failure.unavailable }
        return try records.filter { $0.record.kind == .recipe }.map { saved in
            try RecordsNativeCodec.validate(saved.record)
            guard let bytes = saved.record.nativePayload else { throw ArchiveError.invalidRecipe }
            let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: bytes).validated()
            return .init(id: [saved.record.origin, saved.record.id, recipe.id, saved.id].joined(separator: ":"), recipe: recipe)
        }
    }
}

import SwiftUI
import CoreDomain

struct PrivateRecipeSearchField: View {
    @Binding var query: String
    var body: some View {
        TextField(tonightText("Search recipe titles and ingredients"), text: $query)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityIdentifier("dinner.recipeSearch")
    }
}

struct RecipePinButton: View {
    @ObservedObject var ledger: LedgerModel
    let recipe: CookSoonPin.Recipe
    let owner: String
    let authorize: @MainActor () -> Bool
    private var identifier: String {
        switch recipe {
        case .reviewed(let id): return "dinner.cookSoon.reviewed." + id.uuidString
        case .imported(let id): return "dinner.cookSoon.imported." + id
        }
    }
    private var pin: CookSoonPin { CookSoonPin(owner: owner, recipe: recipe) }

    var body: some View {
        let pinned = ledger.workspace.cookSoonPins.contains(pin)
        Button {
            let origin = ledger.sourceWorkspaceID
            Task {
                let authorized = { authorize() && origin != nil && ledger.sourceWorkspaceID == origin }
                _ = await ledger.change(key: "cook-soon-\(UUID())", reviewedPantryBasis: nil, authorize: authorized) { workspace in
                    guard workspace.cookSoonPins.contains(pin) == pinned else { throw DinnerPlanningError.stalePreview }
                    try workspace.setCookSoon(pin, pinned: !pinned)
                }
            }
        } label: {
            Label(tonightText(pinned ? "Remove from Cook soon" : "Cook soon"), systemImage: pinned ? "pin.fill" : "pin")
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(!authorize() || ledger.saving || ledger.hasPendingSave)
        .accessibilityIdentifier(identifier)
    }
}

#if DEBUG && targetEnvironment(simulator)
extension TonightRecipeLibrary {
    /// Populate only the simulator's disposable workspace. The production library reader and review routes run normally.
    static func seedShopperTestLibrary() async throws {
        guard Set(["--ui-testing", "--shopper-recipe-sources"]).isSubset(of: ProcessInfo.processInfo.arguments) else { return }
        let url = try registryURL()
        guard url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "UITestWorkspace" else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        let registry = try RecoveryRegistry(url: url)
        let origin = "shopper-recipe-fixture"
        guard !(try await registry.refreshList()).contains(where: { $0.record.origin == origin }) else { return }
        let others = (1...74).map { ImportedRecipe(title: "Dinner \($0)", yieldText: "2 servings", ingredients: ["1 cup rice"]) }
        let soup = ImportedRecipe(title: "Sopa de lentejas", yieldText: "4 porciones",
            ingredients: ["1 ½ cups dry lentils", "cilantro al gusto"], steps: ["Simmer the lentils.", "Añade el cilantro."])
        let records = try (others + [soup]).map { try $0.archiveRecord(origin: origin, savedAt: Date(timeIntervalSince1970: 0)) }
        let envelope = try ArchiveCodec.make(records: records, kind: .personalRecovery, origin: origin, revision: "1")
        _ = try await registry.apply(registry.review(envelope))
    }
}
#endif

/// Opt-in bindings live outside immutable shopping history and recipe exports. Forget replaces the protected file.
@MainActor final class TonightProductMemory: ObservableObject {
    @Published private(set) var generation = UUID()
    struct Scope: Equatable {
        let ledger: UUID
        let pantry: UUID
        let owner: String
    }
    private let root: URL
    init(folder: URL) { root = folder }

    private func file(_ scope: Scope) throws -> URL {
        guard scope.owner.utf8.count == 64, scope.owner.allSatisfy(\.isHexDigit) else { throw TonightMealModel.Failure.unavailable }
        return root.appendingPathComponent(scope.pantry.uuidString, isDirectory: true)
            .appendingPathComponent(scope.ledger.uuidString + "-" + scope.owner + ".json")
    }
    private func read(_ file: URL) throws -> [RecipeProductMatch] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try PantryArchiveFiles.read(file, maximum: 2_097_152)
        let rows = try JSONDecoder().decode([RecipeProductMatch].self, from: data)
        guard rows.count <= 4000, Set(rows.map(\.key)).count == rows.count,
              rows.allSatisfy({ $0.recipeDigest.count == 64 && $0.productDigest.count == 64 && $0.recipeRevision >= 0 })
        else { throw TonightMealModel.Failure.unavailable }
        return rows
    }
    private func write(_ rows: [RecipeProductMatch], to file: URL) throws {
        if rows.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        let data = try JSONEncoder().encode(rows)
        guard rows.count <= 4000, data.count <= 2_097_152 else { throw TonightMealModel.Failure.unavailable }
        try PantryArchiveFiles.directory(file.deletingLastPathComponent(), create: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try PantryArchiveFiles.protect(file, permissions: 0o600)
    }
    func records(_ scope: Scope, in workspace: LedgerWorkspace? = nil) throws -> [RecipeProductMatch] {
        let rows = try read(file(scope))
        guard rows.allSatisfy({ $0.key.pantryID == scope.pantry && $0.key.owner == scope.owner }) else { throw TonightMealModel.Failure.unavailable }
        guard let workspace, !rows.isEmpty else { return rows }
        let available = Dictionary(grouping: workspace.mealTemplates + workspace.dinnerPlanning.acceptedDinners.map(\.template), by: \.id)
        let current = rows.filter { row in
            available[row.key.recipeID]?.contains { recipe in
                recipe.revision == row.recipeRevision && recipe.ingredients.contains { $0.id == row.key.ingredientID }
            } == true
        }
        if current != rows { try write(current, to: file(scope)) }
        return current
    }
    func replace(_ previous: RecipeProductMatch?, with next: RecipeProductMatch?, scope: Scope,
                 authorized: () -> Bool) throws {
        guard authorized(), let key = (previous ?? next)?.key, key.pantryID == scope.pantry, key.owner == scope.owner,
              next == nil || next?.key == key else { throw TonightMealModel.Failure.unavailable }
        var rows = try records(scope)
        guard rows.first(where: { $0.key == key }) == previous else { throw TonightMealModel.Failure.stale }
        rows.removeAll { $0.key == key }
        if let next { rows.append(next) }
        try write(rows, to: file(scope))
        generation = UUID()
    }
    func eraseLedger(_ ledger: UUID) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where UUID(uuidString: directory.lastPathComponent) != nil {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix(ledger.uuidString + "-") {
                try FileManager.default.removeItem(at: file)
                generation = UUID()
            }
        }
    }
    func erasePantry(_ pantry: UUID, whole: Bool, survivingFoods: () async throws -> Set<UUID>) async throws {
        let folder = root.appendingPathComponent(pantry.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if whole { try FileManager.default.removeItem(at: folder); generation = UUID(); return }
        let retained = try await survivingFoods()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let rows = try read(file)
            let survivors = rows.filter { retained.contains($0.foodID) }
            if rows != survivors { try write(survivors, to: file); generation = UUID() }
        }
    }
}
