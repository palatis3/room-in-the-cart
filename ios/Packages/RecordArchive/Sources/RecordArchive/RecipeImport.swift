import Foundation

public struct ImportedRecipe: Codable, Equatable, Sendable, Identifiable {
    public var id: String { (try? ArchiveCodec.digest(ArchiveCodec.canonical(self))) ?? title }
    public var title: String
    public var yieldText: String
    public var ingredients: [String]
    public var steps: [String]
    public var sourceURL: String?
    public var notes: String
    public init(title: String, yieldText: String = "", ingredients: [String] = [], steps: [String] = [], sourceURL: String? = nil, notes: String = "") {
        self.title = title; self.yieldText = yieldText; self.ingredients = ingredients
        self.steps = steps; self.sourceURL = sourceURL; self.notes = notes
    }
    public func validated() throws -> ImportedRecipe {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4096, yieldText.utf8.count <= 4096, notes.utf8.count <= 32768,
              [title, yieldText, notes].allSatisfy({ !$0.contains("\0") }),
              ingredients.count <= 1000, steps.count <= 1000,
              (ingredients + steps).allSatisfy({ $0.utf8.count <= 32768 && !$0.contains("\0") }) else { throw ArchiveError.invalidRecipe }
        if let sourceURL, !sourceURL.isEmpty {
            guard sourceURL.utf8.count <= 4096, let components = URLComponents(string: sourceURL),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil,
                  components.user == nil, components.password == nil else { throw ArchiveError.invalidRecipe }
        }
        return self
    }
    public func archiveRecord(origin: String, savedAt: Date = Date()) throws -> ArchiveRecord {
        let recipe = try validated()
        return ArchiveRecord(id: recipe.id, origin: origin, revision: recipe.id, kind: .recipe, title: title,
                             savedAtMilliseconds: ArchiveCodec.milliseconds(savedAt),
                             helperLines: ingredients.map { HelperLine(label: $0) }, nativePayload: try ArchiveCodec.canonical(recipe))
    }
}
public struct RecipeImportReport: Sendable {
    public let recipes: [ImportedRecipe]
    public let duplicateCount: Int
    public let skippedRows: Int
    public let unsupportedFields: [String]
}

/// Documented Recipe JSON-LD profile. Context URLs are inert text, never fetched.
public enum RecipeImporter {
    public static func stage(_ data: Data, existing: [ImportedRecipe] = []) throws -> RecipeImportReport {
        try ArchiveCodec.preflight(data)
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw ArchiveError.malformed }
        let nodes: [Any]
        if let dictionary = root as? [String: Any] {
            if let version = dictionary["formatVersion"] {
                guard let value = version as? Int, value == 1 else { throw ArchiveError.unsupportedVersion }
            }
            if let graph = dictionary["@graph"] as? [Any] { nodes = graph } else { nodes = [dictionary] }
        } else if let array = root as? [Any] { nodes = array }
        else { throw ArchiveError.invalidRecipe }
        guard nodes.count <= ArchiveCodec.maximumRecords else { throw ArchiveError.tooLarge }
        var recipes: [ImportedRecipe] = [], duplicates = 0, skipped = 0, unsupported = Set<String>()
        var known = Set(existing.map(\.id))
        let allowed: Set<String> = ["@context", "@type", "@id", "formatVersion", "name", "recipeYield", "recipeIngredient", "recipeInstructions", "url", "notes", "description"]
        for node in nodes {
            guard let object = node as? [String: Any] else { skipped += 1; continue }
            if let version = object["formatVersion"] {
                guard let value = version as? Int, value == 1 else { throw ArchiveError.unsupportedVersion }
            }
            let types = (object["@type"] as? [String]) ?? (object["@type"] as? String).map { [$0] } ?? []
            guard types.contains(where: { $0 == "Recipe" || $0 == "https://schema.org/Recipe" || $0 == "http://schema.org/Recipe" }) else { skipped += 1; continue }
            unsupported.formUnion(object.keys.filter { !allowed.contains($0) }.map { String($0.prefix(80)) })
            guard let title = object["name"] as? String else { skipped += 1; continue }
            guard object["recipeIngredient"] == nil || object["recipeIngredient"] is [String],
                  object["recipeYield"] == nil || object["recipeYield"] is String,
                  object["url"] == nil || object["url"] is String,
                  object["notes"] == nil || object["notes"] is String else { skipped += 1; continue }
            var steps: [String] = []
            if let text = object["recipeInstructions"] as? String { steps = [text] }
            else if let array = object["recipeInstructions"] as? [Any] {
                var valid = true
                for step in array {
                    if let text = step as? String { steps.append(text) }
                    else if let object = step as? [String: Any], object["@type"] as? String == "HowToStep", let text = object["text"] as? String { steps.append(text) }
                    else { valid = false }
                }
                if !valid { skipped += 1; continue }
            } else if object["recipeInstructions"] != nil { skipped += 1; continue }
            let recipe = ImportedRecipe(title: title, yieldText: object["recipeYield"] as? String ?? "", ingredients: object["recipeIngredient"] as? [String] ?? [], steps: steps, sourceURL: object["url"] as? String, notes: object["notes"] as? String ?? object["description"] as? String ?? "")
            guard (try? recipe.validated()) != nil else { skipped += 1; continue }
            if known.insert(recipe.id).inserted { recipes.append(recipe) } else { duplicates += 1 }
        }
        guard !recipes.isEmpty || duplicates > 0 else { throw ArchiveError.invalidRecipe }
        return RecipeImportReport(recipes: recipes, duplicateCount: duplicates, skippedRows: skipped, unsupportedFields: unsupported.sorted())
    }
}
