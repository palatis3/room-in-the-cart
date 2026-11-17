import Foundation
import RecordArchive

/// The same protected registry used by Records. Imported text remains a source,
/// not an approved typed recipe and never silently gains quantities or servings.
@MainActor enum TonightRecipeLibrary {
    static func registryURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var folder = base.appendingPathComponent("RoomInTheCart", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { folder = base.appendingPathComponent("UITestWorkspace", isDirectory: true) }
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
